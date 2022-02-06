package cherryEpg::Player;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Path::Class;
use File::Basename;
use Log::Log4perl qw(get_logger);
use File::Copy qw();
use File::Glob ':nocase';
use Sys::Hostname;
use File::stat;
use Time::Piece;
use Time::Seconds;
use Gzip::Faster;
use IPC::Run3 qw(run3);
use cherryEpg;
use Fcntl qw/:flock O_WRONLY O_CREAT O_EXCL/;

my $chunkExtension         = '.cts';
my $enhancedChunkExtension = '.ets.gz';
my $tmpExtension           = '.tmp';

my $logger = get_logger('player');

has 'verbose' => (
    is      => 'ro',
    default => 0
);

has 'cherry' => ( is => 'lazy', );

sub _build_cherry {
    my ($self) = @_;

    return cherryEpg->instance( verbose => $self->verbose );
}

sub BUILD {
    my ( $self, $args ) = @_;
}

=head3 delete( )
=head3 delete( $target)

Remove files from carousel directory.
This is not for controlling of the carousel. Use stop().

=cut

sub delete {
    my ( $self, $target ) = @_;

    my $path = $self->cherry->config->{core}{carousel};

    if ( !$target ) {

        # remove all files
        my @list = ();

        my $pattern = file( $path, '*' . $chunkExtension );
        push( @list, glob($pattern) );

        $pattern = file( $path, '*' . $enhancedChunkExtension );
        push( @list, glob($pattern) );

        $pattern = file( $path, '*' . $tmpExtension );
        push( @list, glob($pattern) );

        my $count = unlink(@list);
        $logger->info("all files removed from carousel [$count]") if $count;
        return $count;
    } elsif ( length($target) >= 3 ) {

        # remove files for $target
        my @list = ();

        my $pattern = file( $path, $target . $chunkExtension );
        push( @list, glob($pattern) );

        $pattern = file( $path, $target . $tmpExtension );
        push( @list, glob($pattern) );

        $pattern = file( $path, $target . $enhancedChunkExtension );
        push( @list, glob($pattern) );

        my $count = unlink(@list);
        $logger->info("[$target] removed from carousel") if $count;
        return $count;
    } ## end elsif ( length($target) >=...)
} ## end sub delete

=head3 stop( $target)
=head3 stop( 'EIT')
=head3 stop()

Stop the carousel by removing .cts files.

=cut

sub stop {
    my ( $self, $target ) = @_;

    my $path = $self->cherry->config->{core}{carousel};

    if ( !$target ) {

        # remove all .cts files and .tmp files
        my @list = ();

        my $pattern = file( $path, '*' . $chunkExtension );
        push( @list, glob($pattern) );

        my $count = unlink(@list);
        $logger->info("stop playing all files [$count]") if $count;
        return $count;
    } elsif ( $target eq 'EIT' ) {

        # remove only EITs
        my $pattern = file( $path, 'eit_*' . $chunkExtension );
        my @list    = glob($pattern);

        my $count = unlink(@list);
        $logger->info("stop playing EIT files [$count]") if $count;
        return $count;
    } elsif ( length($target) > 3 ) {

        # remove by $target (filename without extension)
        my $filename = $target . $chunkExtension;

        # stringify
        my $file = file( $path, $filename ) . '';
        if ( -f $file ) {
            my $count = unlink($file);
            $logger->info("stop playing [$target]") if $count;
            return $count;
        }
    } ## end elsif ( length($target) >...)
} ## end sub stop


=head3 load( $target)
=head3 load( $file)

Read $target .ets file from carousel or $file and return $target, $meta, \$pes, undef, $source, \$serialized

=cut

sub load {
    my ( $self, $target ) = @_;

    my $serialized;
    my $zipFile;

    if ( -e $target ) {

        # we have an extenal file
        $zipFile = $target;
        $target  = gmtime->strftime("%Y%m%d%H%M%S");
    } else {

        # the file is in the carousel
        $zipFile = file( $self->cherry->config->{core}{carousel}, $target . $enhancedChunkExtension );
    }

    if ( -r $zipFile ) {
        my $enhanced = try {
            $serialized = gunzip_file($zipFile);
            return YAML::XS::Load($serialized);
        } catch {
            $logger->error("not valid .yaml.gz file [$zipFile]");
            return;
        };

        if ( !$enhanced ) {

            # workaround because of Firefox gzip handling
            $enhanced = try {
                return YAML::XS::LoadFile($zipFile);
            } catch {
                $logger->error("not valid .yaml file [$zipFile]");
                return;
            };
        } ## end if ( !$enhanced )

        return unless ref $enhanced eq 'HASH';

        # verify content
        return
                unless $enhanced->{ts}
            and $enhanced->{dst}
            and $enhanced->{title}
            and ( $enhanced->{bitrate} || $enhanced->{interval} );

        # split up the content
        my $source = delete $enhanced->{source};
        my $ts     = delete $enhanced->{ts};

        return ( $target, $enhanced, \$ts, undef, $source, \$serialized );
    } ## end if ( -r $zipFile )
    $logger->error("file not found [$zipFile]");
    return;
} ## end sub load

=head3 arm( $target, $meta, \$pes, $eit_id)

Create .tmp file with $meta data and $pes in carousel directory
The filename is built from $target -> $target.tmp
Return 1 on success.

=cut

sub arm {
    my ( $self, $target, $meta, $pes, $eit_id ) = @_;

    return unless $target;

    if ( length($$pes) % 188 != 0 ) {
        $logger->error( "PES not multiple of 188 bytes length [" . length($pes) . "]", undef, $eit_id );
        return;
    }

    # prevent quoting of integers
    try {
        $meta->{interval} += 0 if exists $meta->{interval};
        $meta->{bitrate}  += 0 if exists $meta->{bitrate};
        $meta->{tdt}      += 0 if exists $meta->{tdt};
        $meta->{pcr}      += 0 if exists $meta->{pcr};
    };

    # check for redundancy
    if ( $meta->{redundancy} ) {
        my $hostname = hostname() // '-';
        if ( ref( $meta->{redundancy} ) eq 'HASH' and $meta->{redundancy}{$hostname} ) {
            $meta->{dst} = $meta->{redundancy}{$hostname};
        }
        delete $meta->{redundancy};
    } ## end if ( $meta->{redundancy...})

    # verify destination ip:port
    if ( !$meta->{dst} ) {
        $logger->error( "missing destination address:port", undef, $eit_id );
        return;
    }
    if ( $meta->{dst} !~ m/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d{1,5}$/ ) {
        $logger->error( "incorrect format of destination [", $meta->{dst}, "]", undef, $eit_id );
        return;
    }

    my $encoded     = JSON::XS::encode_json($meta);
    my $firstPacket = pack( "CnC", 0x47, 0x1fff, 0x10 ) . "ringelspiel " . $encoded;

    if ( length($firstPacket) > 187 ) {
        $logger->error( "commandstring to long [" . length($firstPacket) . "]", undef, $eit_id );
        return;
    }

    $firstPacket .= "\x00";
    while ( length($firstPacket) < 188 ) {
        $firstPacket .= "\xff";
    }

    my $tempFile = file( $self->cherry->config->{core}{carousel}, $target . $tmpExtension );

    my $out;
    if ( !open( $out, '>', $tempFile ) ) {
        $logger->error( "open temporary export file [$tempFile] : $?", undef, $eit_id );
        return;
    }
    binmode($out);
    print( $out $firstPacket );
    print( $out $$pes );
    close($out);

    $logger->trace( "export " . length($pes) . " bytes to [$tempFile]", undef, $eit_id );

    return 1;
} ## end sub arm

=head3 decode( $target)

Decode the .cts $target im carousel directory and return $meta hash and \$ts
without first packet on success.

=cut

sub decode {
    my ( $self, $target ) = @_;

    return unless $target;

    my $path = $self->cherry->config->{core}{carousel};
    my $file = file( $path, $target . $chunkExtension );

    return if !-r $file;

    my $fh;
    if ( !open( $fh, '<', $file ) ) {
        $logger->warn("open CTS file [$file] : $?");
        return;
    }

    binmode($fh);
    my $ts = do { local $/; <$fh> };
    close($fh);

    if ( length($ts) > 188 ) {

        my $firstPacket = substr( $ts,          0, 188, '' );
        my $header      = substr( $firstPacket, 4, 184 );
        my $prefix      = substr( $header,      0, 12, "" );

        if ( $prefix eq "ringelspiel " ) {

            $header =~ s/\x00\xff+$//;
            my $decoded = try {
                JSON::XS->new->utf8->decode($header);
            };
            if ($decoded) {
                return ( $decoded, \$ts );
            }
        } ## end if ( $prefix eq "ringelspiel ")
    } ## end if ( length($ts) > 188)

    $logger->warn("incorrect CTS file format [$file]");
} ## end sub decode

=head3 isPlaying( $target )

Return 1 if $target .cts file exists.

=cut

sub isPlaying {
    my ( $self, $target ) = @_;

    my $path  = $self->cherry->config->{core}{carousel};
    my $chunk = file( $path, $target . $chunkExtension );

    return -e $chunk;
} ## end sub isPlaying

=head3 play( $target, $eit_id )

Start playing file in carousel directory by renaming the $target file to $target.cts.
$eit_id is used only for logging
During rename the outputfile is locked.
Return $destination on success.

=cut

sub play {
    my ( $self, $target, $eit_id ) = @_;

    my $path        = $self->cherry->config->{core}{carousel};
    my $source      = file( $path, $target . $tmpExtension );
    my $destination = file( $path, $target . $chunkExtension );

    return if !-e $source;

    my $fh;
    if ( !( open( $fh, '+<', $destination ) or sysopen( $fh, $destination, O_WRONLY | O_CREAT | O_EXCL ) ) ) {
        $logger->fatal( "open export file [$destination] : $?", undef, $eit_id );
        exit(1);
    }
    if ( !flock( $fh, LOCK_EX ) ) {
        $logger->fatal( "lock [$destination]", undef, $eit_id );
        exit(1);
    }

    $logger->trace( "lock destination [$target$chunkExtension]", undef, $eit_id );

    seek( $fh, 0, 0 );
    if ( !rename( $source, $destination ) ) {
        $logger->fatal( "rename [$source -> $destination]", undef, $eit_id );
        exit(1);
    }
    close($fh);
    return $destination;
} ## end sub play

=head3 copy( $file)

Import .ets $file by copying the $file with current timestamp to carousel.
No errorchecking just copy!
Return $target of new file.

=cut

sub copy {
    my ( $self, $filepath ) = @_;

    if ( -e $filepath ) {
        my $LIMIT       = 10;
        my $currentTime = gmtime->strftime("%Y%m%d%H%M%S");
        my $target;
        my $count = 0;
        my $zipFile;

        # allow multiple file <LIMIT with same epoch
        do {
            $target  = $currentTime . chr( 97 + $count++ );
            $zipFile = file( $self->cherry->config->{core}{carousel}, $target . $enhancedChunkExtension );
        } while ( -e $zipFile and $count < $LIMIT );

        if ( $count == $LIMIT ) {
            $logger->error("too many ETS file at same moment");
            return;
        }

        if ( File::Copy::copy( $filepath, $zipFile ) ) {
            $logger->info("imported [$filepath] ETS file to [$target]");
            return $target;
        } else {
            $logger->error("importing ETS file [$filepath] : $?");
            return;
        }
    } ## end if ( -e $filepath )
} ## end sub copy

=head3 list()

List all files in carousel with detailed info and return array on success.

=cut

sub list {
    my ($self) = @_;

    my $path = dir( $self->cherry->config->{core}{carousel} );

    my $carousel = {};

    if ( -d -r $path and opendir( my $dir, $path ) ) {
        my @files = readdir($dir);
        closedir($dir);

        foreach my $current (@files) {

            next if $current =~ /^\.\.?$/;

            my ( $target, undef, $extension ) =
                fileparse( $current, ( $enhancedChunkExtension, $chunkExtension, $tmpExtension ) );
            my $file = file( $path, $current );

            next if !-f $file;

            $carousel->{$target}{target} = $target;

            if ( $extension eq $enhancedChunkExtension ) {
                $carousel->{$target}{ets} = 1;

                # open the file
                my ( undef, $meta, $ts ) = $self->load($target);
                if ( !$ts ) {
                    delete $carousel->{$target};
                    next;
                }
                $carousel->{$target}{pid}       = _getPID($ts);
                $carousel->{$target}{meta}      = $meta;
                $carousel->{$target}{size}      = length($$ts);
                $carousel->{$target}{timestamp} = gmtime( stat($file)->mtime )->epoch();
            } elsif ( $extension eq $chunkExtension ) {
                $carousel->{$target}{playing} = 1;

                my ( $meta, $ts ) = $self->decode($target);
                if ( !$ts ) {
                    delete $carousel->{$target};
                    next;
                }
                my $size = length($$ts);
                $carousel->{$target}{pid}       = _getPID($ts);
                $carousel->{$target}{meta}      = $meta;
                $carousel->{$target}{size}      = $size;
                $carousel->{$target}{timestamp} = gmtime( stat($file)->mtime )->epoch();
            } elsif ( $extension eq $tmpExtension ) {
                $carousel->{$target}{tmp}       = 1;
                $carousel->{$target}{size}      = ( -s $file ) - 188;
                $carousel->{$target}{timestamp} = gmtime( stat($file)->mtime )->epoch();
            }
        } ## end foreach my $current (@files)
        my @list = map { $carousel->{$_} } reverse sort keys %{$carousel};

        return \@list;
    } ## end if ( -d -r $path and opendir...)
    return;
} ## end sub list

=head3 dump()

Get target .cts or .ets and analyze it with dvbsnoop.

=cut

sub dump {
    my ( $self, $target ) = @_;

    my $response;
    my $error;

    # try to get .cts
    my ( undef, $ts ) = $self->decode($target);

    if ( !$ts ) {

        # or  from .ets
        ( undef, undef, $ts ) = $self->load($target);
    }

    if ($ts) {

        # trim to <250k
        my $truncated = 0;
        if ( length($$ts) > ( 188 * 1350 ) ) {
            $$ts       = substr( $$ts, 0, 188 * 1350 );
            $truncated = 1;
        }
        try {
            run3( "dvbsnoop -s ts -if - -tssubdecode -nohexdumpbuffer", $ts, \$response, \$error );
            if ($truncated) {
                $response .= '=' x 58 . "\nFile larger than 1350 packets. Truncated for dump!\n";
            }
        } catch {
            my $error = shift;

            if ( $error =~ m/no\ such/i ) {
                $response = "Please install analyzer tool - dvbsnoop.";
            } else {
                $response = "Failed running analyzer tool.";
            }
        };

        $logger->error("running analyzer: $?") if $?;
        return \$response;
    } ## end if ($ts)
} ## end sub dump

sub _getPID {
    my ($ts) = @_;

    my $header = substr( $$ts, 0, 3 );
    my ( undef, $pid ) = unpack( "Cn", $header );
    return $pid & 0x1fff;
} ## end sub _getPID


=head1 AUTHOR

=encoding utf8

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;