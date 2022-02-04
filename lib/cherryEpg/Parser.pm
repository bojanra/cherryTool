package cherryEpg::Parser;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use File::Basename;
use Log::Log4perl;

has source => (
    is  => 'ro',
    isa => sub {
        die "$_[0] file not found" unless -e $_[0];
    },
    required => 1,
);

has logger => (
    is       => 'ro',
    required => 1,
);

sub BUILD {
    my ( $self, $arg ) = @_;

    my $filename = basename( $arg->{source} );

    $self->{report} = {
        source    => $filename,
        parser    => __PACKAGE__,
        errorList => [],
        eventList => [],
    };
} ## end sub BUILD

=head3 error( $format, @args)

Add a message to the report stack.

=cut

sub error {
    my ($self) = shift;

    push( @{ $self->{report}{errorList} }, sprintf( shift @_, @_ ) );
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found TIME MUST BE in GMT

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    return $report;

} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
