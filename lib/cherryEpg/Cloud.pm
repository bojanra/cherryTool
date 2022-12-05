package cherryEpg::Cloud;

use 5.024;
use utf8;
use Digest::MD5;
use File::Copy;
use File::Path qw(remove_tree);
use IPC::ConcurrencyLimit;
use IPC::Run3     qw(run3);
use Log::Log4perl qw(get_logger);
use Moo::Role;
use Path::Class;
use Readonly;
use Try::Tiny;

Readonly my $KEYFILE => '4cloud';
Readonly my $DIREXT  => '.linger';

=head3 isLinger()

Check if cherryEpg is in linger mode - EIT building is disabled.
.cts chunks are synchronized from the "cloud".

=cut

sub isLinger {
    my ($self) = @_;

    return $self->epg->listKey('linger')->{linger};
}

=head3 markLinger( $linger_id)

Set last update marker for $linger_id to now.
Return 1 on success.

=cut

sub markLinger {
    my ( $self, $linger_id ) = @_;

    my $list = $self->epg->listLinger($linger_id);

    my $isValid = grep { $_->{linger_id} eq $linger_id } $list->@*;

    # return if not valid linger_id
    return unless $isValid;

    my $k = $self->epg->addKey( $linger_id => time() );

    return $k;
} ## end sub markLinger

=head3 syncLinger()

Synchronize files from cloud server to carousel by runnning rsync.
Return number of updated files.

=cut

sub syncLinger {
    my ($self) = @_;

    my $host   = $self->epg->listKey('linger')->{linger};
    my $logger = Log::Log4perl->get_logger("system");

    my $limit = IPC::ConcurrencyLimit->new(
        type      => 'Flock',
        max_procs => 1,
        path      => '/tmp/rsyncMulti.flock',
    );

    my $id = $limit->get_lock;
    if ( not $id ) {
        $logger->warn("synchronization concurrency protection");
        return;
    }

    my $keyfile  = file( $self->config->{core}{basedir}, '.ssh', $KEYFILE );
    my $carousel = $self->config->{core}{carousel};

#    $host = "192.168.1.1";

    my $command =
        "rsync -vrztL --delete --stats --timeout=45 -e 'ssh -i $keyfile -o StrictHostKeyChecking=no' $host:/*.ctS $carousel";
    my $output;
    my $error;

    try {
        run3( $command, undef, \$output, \$error );
    };

    my $exitcode = $?;

    if ($exitcode) {
        my $data = {
            errorList  => [ split( /\n/, $error ) ],
            reportList => [ split( /\n/, $output ) ],
        };
        $logger->error( "synchronization [$exitcode]", undef, undef, $data );
        return;
    } ## end if ($exitcode)

    # transfer succesfull
    $output =~ s/,//gms;
    my @match = $output =~ m/^Number of files: (\d+) .+^Total file size: (\d+) .+received: (\d+)/ms;

    #list$(.*)^sent (\d+).+^total size is ([\d,]+)/ms;

    if (@match) {
        my $count    = $match[0];
        my $synced   = $match[1];
        my $received = $match[2];
        $logger->info("synchronized [$count] files, [$synced] bytes, received [$received] bytes");
        return $count;
    } else {
        my $data = { reportList => [ split( /\n/, $output ) ], };
        $logger->warn( "synchronized", undef, undef, $data );
        return;
    }
} ## end sub syncLinger

=head3 getLingerKey( $forced)

Generate ed25519 keypair if not existing. When $forced overwrite the current.
Return the current valid public key.

=cut

sub getLingerKey {
    my ( $self, $forced ) = @_;

    my $output;
    my $error;
    my $input  = $forced ? 'y' : 'n';
    my $logger = Log::Log4perl->get_logger("system");

    my $keyfile = file( $self->config->{core}{basedir}, '.ssh', $KEYFILE );

    try {
        run3( "ssh-keygen -t ed25519 -N '' -f $keyfile -q", \$input, \$output, \$error );
    };

    my $publickeyfile = $keyfile . '.pub';
    if ( -e $publickeyfile && -f _ && -r _ && open( my $file, '<', $publickeyfile ) ) {
        my $line = do { local $/; <$file> };
        close($file);

        if ( $line =~ m/ssh-ed25519 (.+) / ) {
            return $1;
        }
    } ## end if ( -e $publickeyfile...)

    $logger->error("ssh public key [$keyfile]");
    return;
} ## end sub getLingerKey

=head3 updateAuthorizedKeys()

Update authorized_keys file with entries from db.
Remove all other non rsync related.
Return number of rows in file.

=cut

sub updateAuthorizedKeys {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $knownhostsfile = file( $self->config->{core}{basedir}, '.ssh', 'authorized_keys' );

    my @content;

    # read an existing file
    if ( -e $knownhostsfile ) {
        if ( open( my $file, '<', $knownhostsfile ) ) {
            @content = <$file>;
            close($file);
        } else {
            $logger->error("reading [$knownhostsfile]");
            return;
        }
    } ## end if ( -e $knownhostsfile)

    # remove existing entries
    @content = grep { !m/command.+shell/ } @content;

    my $count = 0;
    foreach my $linger ( $self->epg->listLinger()->@* ) {
        my $line =
              qq|command="LC_ALL=en_US.UTF-8 PERL5LIB=/var/lib/cherryepg/cherryTool/lib:/var/lib/cherryepg/perl5/lib/perl5 |
            . qq|/var/lib/cherryepg/bin/shell $linger->{linger_id}"|
            . qq|,no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding |
            . qq|ssh-ed25519 $linger->{public_key} -\n|;
        push( @content, $line );
        $count += 1;
    } ## end foreach my $linger ( $self->...)

    # write file to disk
    if ( open( my $file, '>', $knownhostsfile ) ) {
        print( $file @content );
        close($file);
        $logger->info("writing [$count] linger to [$knownhostsfile]");
        return scalar @content;
    } else {
        $logger->error("writing [$knownhostsfile]");
        return;
    }
} ## end sub updateAuthorizedKeys

=head3 installRrsync()

Verify that rrsync is executable and in the path. If not, copy it or link.
Return 1 on success.

=cut

sub installRrsync {
    my ($sefl) = 0;

    my $rrsync = file( $ENV{'HOME'}, 'bin', 'rrsync' );

    return 1 if -x $rrsync;

    # Ubuntu 22.04
    # Debian 11
    my $origin = '/usr/bin/rrsync';
    if ( -x $origin ) {
        return link( $origin, $rrsync );
    }

    # Turnkey 16.1
    my $source = '/usr/share/doc/rsync/scripts/rrsync';
    if ( -e $source ) {

        my $content = try {
            local $/;
            open( my $fh, '<:encoding(UTF-8)', $source ) || return;
            <$fh>;
        };

        if ( $content && open( my $wh, '>:encoding(UTF-8)', $rrsync ) ) {
            print( $wh $content );
            return 1 if close($wh) && chmod( 0774, $rrsync );
        }
    } ## end if ( -e $source )

    return;
} ## end sub installRrsync

=head3 updateSyncDirectory()

Build the server environment for linger sites.
mkdir the directories inside carousel.
Remove old symbol links.
Remove old directories if empty.
Return 1 on success.

=cut

sub updateSyncDirectory {
    my ($self) = @_;

    my $logger   = Log::Log4perl->get_logger("system");
    my $carousel = $self->config->{core}{carousel};

    # get list of existing subdirs
    my @all;
    if ( -d $carousel && -r _ && opendir( my $dir, $carousel ) ) {
        @all = grep {/$DIREXT$/} readdir($dir);
        closedir($dir);
    } else {
        return;
    }

    my $problemCount;

    # walk over linger sites
    foreach my $linger ( { linger_id => 'COMMON' }, $self->epg->listLinger()->@* ) {
        my $subdir       = $linger->{linger_id} . '.linger';
        my $completePath = dir( $carousel, $subdir );

        if ( grep {/^$subdir$/} @all ) {

            # remove symbol links to .eit files
            if ( opendir( my $lir, $completePath ) ) {
                my @element = readdir($lir);
                closedir($lir);
                my @symbol = grep {-l} map { dir( $completePath, $_ ) } @element;

                if ( unlink(@symbol) != scalar @symbol ) {
                    $logger->error( "reset", undef, undef, \@symbol );
                    $problemCount += 1;
                }

                # remove this subdir from the found subdirs list
                @all = grep { !/^$subdir$/ } @all;
                next;
            } else {
                $logger->error( "open [" . $completePath . "]" );
                $problemCount += 1;
            }
        } else {

            # add subdir
            if ( !mkdir($completePath) ) {
                $logger->error( "mkdir [" . $completePath . "]" );
                $problemCount += 1;
            }
        } ## end else [ if ( grep {/^$subdir$/...})]
    } ## end foreach my $linger ( { linger_id...})

    # remove all other subdirs
    my @noneed = map { dir( $carousel, $_ ) } @all;
    if ( remove_tree( @noneed, { keep_root => 0 } ) < @noneed ) {
        $logger->error( "unlink", undef, undef, \@noneed );
        $problemCount += 1;
    }

    return !$problemCount;
} ## end sub updateSyncDirectory

=head3 makeSymbolicLink( $eitPath)

Make symbol links for linger sites to common or general .cts files.
$eitPath contains hash of paths by eit_id.
We only add links. Old ones are not removed. Use updateSyncDirectory for this.
Return 1 on success.

=cut

sub makeSymbolicLink {
    my ( $self, $eitPath ) = @_;

    # build eit_id to path hash
    my $errorCount = 0;
    my $carousel   = $self->config->{core}{carousel};
    my $logger     = Log::Log4perl->get_logger("system");

    # walk over linger sites
    foreach my $linger ( $self->epg->listLinger()->@* ) {
        my $subdir = $linger->{linger_id} . '.linger';

        foreach my $eit ( sort { $a <=> $b } keys $linger->{info}{eit}->%* ) {
            my $target = $eitPath->{$eit};
            $target =~ m|/([^/]+)$|;
            my $theFile = $1;

            # change extension to .ctS
            $theFile =~ s/s$/S/;
            my $link = file( $carousel, $subdir, $theFile );
            if ( !-l $link ) {
                if ( symlink( "..$target", $link ) ) {
                    $logger->info( "add symbolic link", undef, undef, ["$link -> $target"] );
                } else {
                    $logger->error( "add symbolic link", undef, undef, ["$link -> $target"] );
                    $errorCount += 1;
                }
            } ## end if ( !-l $link )
        } ## end foreach my $eit ( sort { $a...})
    } ## end foreach my $linger ( $self->...)

    return $errorCount == 0;
} ## end sub makeSymbolicLink

=head1 AUTHOR

=encoding utf8

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
