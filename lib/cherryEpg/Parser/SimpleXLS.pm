package cherryEpg::Parser::SimpleXLS;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use Time::Piece;
use Time::Seconds;
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

        # there must be at least 6 columns
        next unless ( scalar @cells >= 6 and $cells[0] and $cells[0] ne "" );

        # skip header rows
        if ( $cells[0] =~ /date/i ) {

            # but use the first one as column description
            if ( 0 == scalar keys %mapping ) {

                # find the requested columns and generate a maptable
                for ( my $i = 0 ; $i <= $#cells ; $i++ ) {
                    next if !$cells[$i];

                SWITCH: for ( $cells[$i] ) {
                        /date/i     && do { $mapping{$i} = 0; };
                        /time/i     && do { $mapping{$i} = 1; };
                        /duration/i && do { $mapping{$i} = 2; };
                        /title/i    && do { $mapping{$i} = 3; };
                        /short/i    && do { $mapping{$i} = 4; };
                        /synopsis/i && do { $mapping{$i} = 5; };
                    } ## end SWITCH: for ( $cells[$i] )
                } ## end for ( my $i = 0 ; $i <=...)

            } ## end if ( 0 == scalar keys ...)

            next;
        } ## end if ( $cells[0] =~ /date/i)

        # map the read fields in the correct order
        @remapped =
            map { $cells[$_] }
            sort { $mapping{$a} <=> $mapping{$b} } keys %mapping;

        #    0      1      2          3       4       5
        my ( $date, $time, $duration, $title, $short, $synopsis ) = @remapped;
        $time     //= '';
        $duration //= '';
        $title    //= '';
        $short    //= '';
        $synopsis //= '';

        my $start;
        if ( $date =~ m|^(\d+)[/\.](\d+)[/\.](\d\d)$| ) {

            # dd/mm/yy
            $start = localtime->strptime( $date, "%d/%m/%y" );
        } elsif ( $date =~ m|^(\d+)[/\.](\d+)[/\.](\d{4})| ) {

            # dd/mm/yyyy
            $start = localtime->strptime( $date, "%d/%m/%Y" );
        } else {
            $self->error( "Incorrect date format in row %i: %s", $rowCounter, $date );
            next;
        }

        if ( $time =~ m/^(\d+):(\d+)$/ ) {

            # hh:mm
            my $hour = $1;
            my $min  = $2;
            $start += ONE_HOUR * $hour + ONE_MINUTE * $min;
        } elsif ( $time =~ m/^(\d+):(\d+):(\d+)$/ ) {

            # hh:mm:ss
            my $hour = $1;
            my $min  = $2;
            my $sec  = $3;
            $start += ONE_HOUR * $hour + ONE_MINUTE * $min + $sec;
        } ## end elsif ( $time =~ m/^(\d+):(\d+):(\d+)$/)

        if ( $duration =~ m/^(\d+):(\d+):(\d+)$/ ) {
            $duration = ( $1 * 60 + $2 ) * 60 + $3;
        } elsif ( $duration =~ m/^(\d+)$/ ) {
            $duration = $1;
        } else {
            $self->error( "Incorrect duration in row %i: %s", $rowCounter, $duration );
            next;
        }

        # build event
        my $event = {
            start    => $start->epoch,
            duration => $duration,
            title    => $title,
            subtitle => $short,
            synopsis => $synopsis,
        };

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
