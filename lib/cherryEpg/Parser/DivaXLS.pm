package cherryEpg::Parser::DivaXLS;

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

    my $eBook = ReadData( $self->source );

    my $sheet = $eBook->[1];

    my $last;

    if ( !$sheet ) {
        $self->error("Spreadsheet format not supported!");
        return $report;
    }

    $report->{linecount} = $sheet->{maxrow};

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my (
            $date, $time,  undef, $title,  undef,       $subtitle, undef, undef,
            undef, $genre, undef, $actors, $originYear, $country,  $synopsis
           )
            = Spreadsheet::Read::row( $sheet, $rowCounter );

        # skip rows without date and first row
        next
            if !defined $date
            or $date eq ""
            or $date =~ m/datum/i
            or $date =~ m/date/i;

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
            $self->error("Unknown date format [$rowCounter] $date");
            next;
        }

        # add seconds to time
        if ( $time =~ m/^(\d+):(\d+):?(\d*)$/ ) {
            $hour = $1;
            $min  = $2;
            $sec  = ( defined $3 and $3 ne "" ) ? $3 : 0;
        } else {
            $self->error("Unknown time format [$rowCounter] $time");
            next;
        }

        my $start = localtime->strptime( "$year-$month-$day $hour:$min:$sec", "%Y-%m-%d %H:%M:%S" );

        # correct TV schedule anomaly
        if ( $start < $last ) {
            $start += ONE_DAY;
        }

        $last = $start;

        # build event
        my $event = {
            start => $start->epoch,
            title => $title,
        };

        if ( defined $subtitle && $subtitle ne "" ) {
            $event->{subtitle} = $subtitle;
        } else {
            $event->{subtitle} = $genre;
        }

        if ( defined $synopsis && $synopsis ne "" ) {
            $synopsis =~ s/\n/ /gs;
            $event->{synopsis} = $synopsis;

            if (    defined $country
                and $country ne ""
                and defined $originYear
                and $originYear ne "" ) {

                # add country and year
                $event->{synopsis} =~ s/\s*$/, $country $originYear/;
            } ## end if ( defined $country ...)

            if ( defined $actors && $actors ne "" ) {

                # add actors
                $event->{synopsis} =~ s/\s*$/ - $actors/;
            }
        } ## end if ( defined $synopsis...)

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
