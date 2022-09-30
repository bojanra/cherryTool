package cherryEpg::Parser::ScopusXLS;

use 5.024;
use utf8;
use Moo;
use Spreadsheet::Read qw( row ReadData);
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.23';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $book = Spreadsheet::Read->new( $self->source );

    my $sheet = $book->sheet('Events');

    if ( !$sheet ) {
        $self->error("Sheet 'Events' not found. Incorrect XLS format!");
        return $report;
    }

    my %mapping;

    $report->{linecount} = $sheet->maxrow;

    foreach my $rowCounter ( 1 .. $sheet->maxrow ) {

        # get cells from row
        my @cells = $sheet->row($rowCounter);
        my @remapped;

        # there first column must be a hex number
        next unless $cells[0] =~ m/^0x\d+$/;

        #    0         1      2      3          4       5       6
        my (
            $eventId, $date, $time, $duration, $title, $short, $description,

            #    7      8          9      10     11     12     13        14
            $item, $synopsis, undef, undef, undef, undef, $country, $parental_rating
           )
            = @cells;

        my $start;
        if ( $date =~ m|^(\d+)[/\.](\w+)[/\.](\d+)$| ) {

            # replace . with /
            $date =~ s|\.|/|g;

            # 28/jul/2020
            $start = localtime->strptime( $date, "%d/%b/%Y" );
        } else {
            $self->error( "Incorrect date format in row [%i] %s", $rowCounter, $date );
            next;
        }

        if ( $time =~ m/^(\d+):(\d+):(\d+)$/ ) {

            # hh:mm:ss
            my $hour = $1;
            my $min  = $2;
            my $sec  = $3;
            $start += ONE_HOUR * $hour + ONE_MINUTE * $min + $sec;
        } else {
            $self->error( "Incorrect time format in row [%i] %s", $rowCounter, $time );
            next;
        }

        if ( $duration =~ m/^(\d+):(\d+):(\d+)$/ ) {
            $duration = ( $1 * 60 + $2 ) * 60 + $3;
        } else {
            $self->error( "Incorrect duration in row [%i] %s", $rowCounter, $duration );
            next;
        }

        if ( !defined $title || $title eq '' ) {
            $self->error( "Missing title row [%i]", $rowCounter );
            next;
        }

        # build event
        my $event = {
            start    => $start->epoch,
            duration => $duration,
            title    => $title,
            subtitle => $short    // "",
            synopsis => $synopsis // "",
        };

        if ( $parental_rating =~ m|^0x\w+$| ) {
            my $code = hex($parental_rating);
            $event->{parental_rating} = $code + 3;
        }

        $event->{country_code} = uc($country);

        # push to array
        push( @{ $report->{eventList} }, $event );
    } ## end foreach my $rowCounter ( 1 ...)
    return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
