package cherryEpg::Parser::VasKanalXLS;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Time::Piece;
use Time::Seconds;
use Spreadsheet::Read qw( row ReadData);

extends 'cherryEpg::Parser::SimpleXLS';

our $VERSION = '0.28';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

sub rowHandler {
    my ( $self, $sheet, $rowCounter ) = @_;

    my @cell = Spreadsheet::Read::row( $sheet, $rowCounter );

    state @mapping;

    # there must be at least 6 columns
    return unless ( scalar @cell >= 6 );

    # try to find the header row
    if ( !@mapping && ( join( '', @cell ) =~ /datum/i ) ) {

        # find the requested columns and generate a maptable
        my $order = {};
        foreach (@cell) {
            state $i = 0;

            /datum/i     && do { $order->{$i} = 0; };
            /ura/i       && do { $order->{$i} = 1; };
            /naslov/i    && do { $order->{$i} = 2; };
            /podnaslov/i && do { $order->{$i} = 3; };
            /opis/i      && do { $order->{$i} = 4; };
            /voditelji/i && do { $order->{$i} = 5; };
            $i += 1;
        } ## end foreach (@cell)
        @mapping = sort { $order->{$a} <=> $order->{$b} } keys $order->%*;
        return;
    } ## end if ( !@mapping && ( join...))

    return until @mapping;

    # map the read fields in the correct order
    #    0      1      2       3       4          5
    my ( $date, $time, $title, $short, $synopsis, $voditelji ) =
        map { $cell[$_] } @mapping;
    $time      //= '';
    $title     //= '';
    $short     //= '';
    $synopsis  //= '';
    $voditelji //= '';

    my $start;
    if ( $date =~ m|^(\d+)\.(\d+)\.(\d\d)$| ) {

        # dd.mm.yy
        $start = try {
            localtime->strptime( $date, "%d.%m.%y" );
        } catch {
            $self->error( "date not in format DD.MM.YY in row %i [%s]", $rowCounter, $date );
        };
    } elsif ( $date =~ m|^(\d+)/(\d+)/(\d\d)$| ) {

        # dd/mm/yy
        $start = try {
            localtime->strptime( $date, "%d/%m/%y" );
        } catch {
            $self->error( "date not in format DD/MM/YY in row %i [%s]", $rowCounter, $date );
        };
    } elsif ( $date =~ m|^(\d+)\.(\d+)\.(\d{4})| ) {

        # dd.mm.yyyy
        $start = try {
            localtime->strptime( $date, "%d.%m.%Y" );
        } catch {
            $self->error( "date not in format DD.MM.YYYY in row %i [%s]", $rowCounter, $date );
        };
    } elsif ( $date =~ m|^(\d+)/(\d+)/(\d{4})| ) {

        # dd/mm/yyyy
        $start = try {
            localtime->strptime( $date, "%d/%m/%Y" );
        } catch {
            $self->error( "date not in format DD/MM/YYYY in row %i [%s]", $rowCounter, $date );
        };
    } ## end elsif ( $date =~ m|^(\d+)/(\d+)/(\d{4})|)

    if ( !$start ) {
        $self->error( "date format unknown in row %i [%s]", $rowCounter, $date );
        return;
    }

    if ( $time =~ m/^(\d+)[:\.](\d+)$/ ) {

        # hh:mm
        # hh.mm
        my $hour = $1;
        my $min  = $2;
        $start += ONE_HOUR * $hour + ONE_MINUTE * $min;
    } elsif ( $time =~ m/^(\d+):(\d+):(\d+)$/ ) {

        # hh:mm:ss
        my $hour = $1;
        my $min  = $2;
        my $sec  = $3;
        $start += ONE_HOUR * $hour + ONE_MINUTE * $min + $sec;
    } else {

        $self->error( "time format unknown in row %i [%s]", $rowCounter, $time );
        return;
    }

    # build event
    my $event = {
        start    => $start->epoch,
        title    => $title,
        subtitle => $short,
    };

    if ($synopsis) {
        $event->{synopsis} = $synopsis;
        $event->{synopsis} =~ s/\s*$/ - $voditelji/ if $voditelji;
    } else {
        $event->{synopsis} = $voditelji;
    }

    return $event;
} ## end sub rowHandler

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
