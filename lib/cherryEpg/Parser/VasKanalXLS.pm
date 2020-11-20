package cherryEpg::Parser::VasKanalXLS;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Time::Piece;
use Spreadsheet::Read qw( row ReadData);

extends 'cherryEpg::Parser';

our $VERSION = '0.26';

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

    my $eBook = try {
        ReadData( $self->source );
    };

    if ( !$eBook ) {
        $self->error("Spreadsheet format not supported!");
        return $report;
    }

    my $sheet = $eBook->[1];

    if ( !$sheet ) {
        $self->error("No sheet found!");
        return $report;
    }

    $report->{linecount} = $sheet->{maxrow};

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my ( $date, $time, $title, $subtitle, undef, undef, $moderator, undef, $synopsis ) =
            Spreadsheet::Read::row( $sheet, $rowCounter );

        # skip rows without date and first row
        next if !defined $date || $date eq "" || $date =~ m/datum/i;

        my ( $year, $month, $day, $hour, $min, $sec );

        # convert date in different formats
        if ( $date =~ m/^(\d{4})-(\d+)-(\d+)$/ ) {

            # this is o.k. 2013-04-23
            $year  = $1;
            $month = $2;
            $day   = $3;
        } elsif ( $date =~ m/^(\d+)[\/\.](\d+)[\/\.](\d{4})$/ ) {

            # convert from 03/01/2012
            # or 03.05.2016
            $year  = $3;
            $month = $2;
            $day   = $1;
        } elsif ( $date =~ m/^(\d+)-(\d+)-(\d+)$/ ) {

            # convert from 1-23-14    month-day-year
            $year  = $3 + 2000;
            $month = $1;
            $day   = $2;
        } else {
            $self->error("Unknown date format in row [$rowCounter] $date");
            next;
        }

        # get time
        if ( $time =~ m/^(\d+)[:\.](\d+)$/ ) {

            # from hh:mm
            $hour = $1;
            $min  = $2;
            $sec  = 0;
        } elsif ( $time =~ m/^(\d+)[:\.](\d+)[:\.](\d+)$/ ) {

            #from hh:mm:ss
            $hour = $1;
            $min  = $2;
            $sec  = $3;
        } else {
            $self->error("Unknown time format in row [$rowCounter] $time");
            next;
        }
        my $start = localtime->strptime( "$year-$month-$day $hour:$min:$sec", "%Y-%m-%d %H:%M:%S" );

        # build event
        my $event = {
            start    => $start->epoch,
            title    => $title,
            subtitle => $subtitle,
        };

        $moderator //= "";

        if ( defined $synopsis and $synopsis ne "" ) {
            $synopsis =~ s/\n/ /gs;
            $event->{synopsis} = $synopsis;
            $event->{synopsis} =~ s/\s*$/ - $moderator/ if $moderator;
        } else {
            $event->{synopsis} = $moderator if $moderator;
        }

        # push to array
        push( @{ $report->{eventList} }, $event );
    } ## end foreach my $rowCounter ( 1 ...)

    return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
