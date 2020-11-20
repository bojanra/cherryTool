package cherryEpg::Parser::MezzoXLS;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use Time::Piece;
use Spreadsheet::Read qw( row ReadData);

extends 'cherryEpg::Parser';

our $VERSION = '0.24';

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

    if ( !$sheet ) {
        $self->error("Spreadsheet format not supported!");
        return $report;
    }

    my %mapping;

    $report->{linecount} = $sheet->{maxrow};

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my @cells = Spreadsheet::Read::row( $sheet, $rowCounter );
        my @remapped;

        # there must be at least 8 columns
        next unless ( scalar @cells >= 8 and $cells[0] and $cells[0] ne "" );

        # skip header rows
        if ( $cells[0] =~ /broadcast/i ) {

            # but use the first one
            if ( 0 == scalar keys %mapping ) {

                # find the requested columns and generate a maptable
                for ( my $i = 0 ; $i <= $#cells ; $i++ ) {
                    next if !$cells[$i];

                SWITCH: for ( $cells[$i] ) {
                        /broadcast/i  && do { $mapping{$i} = 0; };
                        /start/i      && do { $mapping{$i} = 1; };
                        /duration/i   && do { $mapping{$i} = 2; };
                        /title/i      && do { $mapping{$i} = 3; };
                        /production/i && do { $mapping{$i} = 4; };
                        /category/i   && do { $mapping{$i} = 5; };
                        /directors/i  && do { $mapping{$i} = 6; };
                        /resume/i     && do { $mapping{$i} = 7; };
                    } ## end SWITCH: for ( $cells[$i] )
                } ## end for ( my $i = 0 ; $i <=...)

            } ## end if ( 0 == scalar keys ...)

            next;
        } ## end if ( $cells[0] =~ /broadcast/i)

        # map the read fields in the correct order
        @remapped =
            map { $cells[$_] }
            sort { $mapping{$a} <=> $mapping{$b} } keys %mapping;

        #    0      1      2          3       4              5          6           7
        my ( $date, $time, $duration, $title, $producedYear, $category, $directors, $synopsis ) = @remapped;

        my ( $year, $month, $day, $hour, $min, $sec );

        # convert date in different formats
        if ( $date =~ m/^(\d{4})-(\d+)-(\d+)$/ ) {

            # this is o.k. 2013-04-23
            $year  = $1;
            $month = $2;
            $day   = $3;
        } elsif ( $date =~ m/^(\d+)\/ (\d+)\/ (\d{4})$/ ) {

            # convert from 03/ 05/ 2012  month.day.year
            $year  = $3;
            $month = $1;
            $day   = $2;
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

        if ( $duration =~ m/^(\d+):(\d+):(\d+)$/ ) {
            $duration = ( $1 * 60 + $2 ) * 60 + $3;
        } else {
            $self->error("Incorrect duration row [$rowCounter] $duration");
            next;
        }

        # build event
        my $event = {
            start    => $start->epoch,
            title    => $title,
            subtitle => $category,
            duration => $duration,
        };

        my @list;
        push( @list, $synopsis )  if $synopsis  and $synopsis ne '';
        push( @list, $directors ) if $directors and $directors ne '';
        push( @list, $year )      if $year      and $year ne '';

        $event->{synopsis} = join( ' - ', @list );
        $event->{synopsis} =~ s/[\n\r]+/, /mg;
        $event->{synopsis} =~ s/ {2,}/ /mg;

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
