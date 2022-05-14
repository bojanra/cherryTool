package cherryEpg::Parser::MlavaXLS;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use Time::Piece;
use Spreadsheet::Read qw( row ReadData);

extends 'cherryEpg::Parser::SimpleXLS';

our $VERSION = '0.13';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3

Remap original schedule data to next 7 days.

=cut

around 'parse' => sub {
    my ( $orig, $self, $parserOption ) = @_;

    my $report = $orig->( $self, $parserOption );

    my $eventList = $report->{eventList};

    my $now = localtime->epoch;

    foreach my $event ( @{$eventList} ) {
        while ( $event->{start} < $now ) {

            # add week seconds
            $event->{start} += 7 * 24 * 60 * 60;
        }
    } ## end foreach my $event ( @{$eventList...})

    return $report;
};

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
