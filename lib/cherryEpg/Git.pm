package cherryEpg::Git;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use File::Basename;
use Sys::Hostname;
use Log::Log4perl qw(get_logger);
use Git::Repository;

my $logger = get_logger('system');

has 'repository' => ( is => 'lazy', );
has 'branch'     => ( is => 'lazy' );

sub _build_repository {
    my ($self) = @_;

    my $gitDir = ( fileparse(__FILE__) )[1];

    return try {
        Git::Repository->new(
            work_tree => $gitDir,
            {
                env   => { LC_ALL => 'C' },
                quiet => 1,
                env   => {
                    GIT_COMMITTER_EMAIL => 'info@cherryhill.eu',
                    GIT_COMMITTER_NAME  => hostname,
                },
            }
        );
    };
} ## end sub _build_repository

sub _build_branch {
    my ($self) = @_;

    return if !$self->repository;
    return try {
        return $self->repository->run(qw|rev-parse --abbrev-ref HEAD|);
    };
} ## end sub _build_branch

=head3 fixHook( )

Fix the post-merge hook script to restart cherryWeb after pull.

=cut

sub fixHook {
    my ($self) = @_;

    $self->{status} = undef;
    return if !$self->repository;

    # get top level directory
    my $top = try {
        return $self->repository->run(qw|rev-parse --show-toplevel|);
    };

    return if !$top;
    $top .= "/.git/hooks/post-merge";

    my $hook;
    if ( -e $top && -x _ && open( $hook, '<', $top ) ) {

        # check for sleep command
        my $script = do { local $/; <$hook>; };
        return 1 if $script =~ m/sleep \d/gm;
    } ## end if ( -e $top && -x _ &&...)

    if ( !open( $hook, '>', $top ) ) {
        $logger->error("update post-hook");
        return;
    } else {
        print( $hook "#!/bin/bash\n( sleep 2; systemctl --user restart cherryWeb.service) &\nexit 0\n" );
        close($hook);

        chmod( 0755, $top );
        $logger->info("update post-hook");
        return 1;
    } ## end else [ if ( !open( $hook, '>'...))]
} ## end sub fixHook

=head3 update( )

Update status of local, remote (origin) repository.

=cut

sub update {
    my ($self) = @_;

    $self->{status} = undef;
    return if !$self->repository;

    my $status = {};

    $status->{hook} = $self->fixHook() // 0;

    # check for local changes
    $status->{modification} = try {
        return scalar( grep { $_ !~ /^\?\?/ } $self->repository->run(qw|status -s|) );
    };

    $status->{fetch} = try {
        $self->repository->run(qw|remote update|);
        return $? == 0;
    };

    $status->{localCommit} = try {
        return $self->repository->run(qw|rev-list --count @{u}..|);
    };

    $status->{originCommit} = try {
        return $self->repository->run(qw|rev-list --count ..@{u}|);
    };

    $logger->info( "Fetch/Hook/Modification/LocalCommit/OriginCommit: "
            . ( $status->{fetch}        ? "ok"        : "error" ) . " / "
            . ( $status->{hook}         ? "installed" : "error" ) . " / "
            . ( $status->{modification} ? "present"   : "none" ) . " / "
            . $status->{localCommit} . " / "
            . $status->{originCommit}
            . ( $status->{fetch} ? "" : "!" ) );

    $self->{status} = 1;

    return $status;
} ## end sub update

=head3 upgrade( )

Try to pull --rebase.

=cut

sub upgrade {
    my ($self) = @_;

    return if !$self->repository;

    $self->update() if !$self->{status};

    # upgrade
    my @report = try { return $self->repository->run(qw|pull --rebase |); } catch { return (); };
    my $error  = $?;

    if ($error) {
        $logger->error( "upgrade repository", undef, undef, \@report );
    } else {
        $logger->info( "upgrade repository", undef, undef, \@report );
    }

    return ( $error == 0 );

} ## end sub upgrade

=head1 AUTHOR

=encoding utf8

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
