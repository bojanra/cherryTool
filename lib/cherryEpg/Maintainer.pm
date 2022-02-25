package cherryEpg::Maintainer;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use IPC::Run3 qw(run3);
use Gzip::Faster;
use File::Temp qw(tempfile);
use Log::Log4perl qw(get_logger);
use cherryEpg;

has 'verbose' => (
    is      => 'ro',
    default => 0
);

has 'pod' => (
    is      => 'rw',
    default => ''
);

has 'name' => ( is => 'rw', );

has 'output' => ( is => 'rw', );

=head3 load( $filepath)

Decode, save to file, check, extract POD.
Return 1 on success.

=cut

sub load {
    my ( $self, $filepath ) = @_;

    my $zip = try {
        local $/;
        open( my $fh, '<:raw', $filepath ) || return;
        <$fh>;
    };

    $zip =~ s/^.+?!//;
    my $plain = gunzip($zip);

    return unless $plain;

    my $fh = File::Temp->new( TEMPLATE => 'cherryMaintainXXXXX', DIR => '/tmp' );

    print( $fh $plain );
    close($fh);

    return unless $self->check( $fh->filename );

    $self->{fh} = $fh;

    $self->{pod} = $self->extractPod( $fh->filename );

    # extract name
    if ( $self->{pod} =~ /NAME\s*?\n\s*(.+)\s*$/m ) {
        $self->{name} = $1;
    }

    return 1;
} ## end sub load

=head3 extractPod( $filepath)

Run pod2text on $filepath and return POD

=cut

sub extractPod {
    my ( $self, $filepath ) = @_;

    my $pod;
    run3( "pod2text $filepath", \undef, \$pod, \undef );

    utf8::decode($pod);

    return if $?;
    return $pod;
} ## end sub extractPod

=head3 apply( )

Run the maintenance script from temporary file.

=cut

sub apply {
    my ($self) = @_;

    my $filepath = $self->{fh}->filename;
    my $output;

    # this is required to use the logger
    my $cherry = cherryEpg->instance();
    my $logger = get_logger('system');

    run3( "perl $filepath", \undef, \$output, \undef );

    utf8::decode($output);

    my $report = [$output];
    $self->{output} = $output;
    my $name = $self->name // $filepath;

    if ($?) {
        $logger->error( "Applying [$name] to the system", undef, undef, $report );
        return;
    } else {
        $logger->info( "Applying [$name] to the system", undef, undef, undef );
        return 1;
    }
} ## end sub apply

=head3 check( $filepath )

Check the $file (run with perl -c).
Return 1 on success.

=cut

sub check {
    my ( $self, $filepath ) = @_;

    run3( "perl -c $filepath", \undef, \undef, \undef );

    return if $?;

    # success
    return 1;
} ## end sub check

=head3 convert( $filepath )

Convert the provided file into maintenance package.

=cut

sub convert {
    my ( $self, $filepath ) = @_;

    return unless -e $filepath;
    return unless $self->check($filepath);

    my $zip = 'This is a cherryEpg maintenance package. Do not modify!' . gzip_file($filepath);

    return $zip;
} ## end sub convert

=head1 AUTHOR

=encoding utf8

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
