package cherryEpg::Parser::SimpleXLS;

use 5.024;
use utf8;
use Moo;
use Spreadsheet::Read;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.27';

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
    Spreadsheet::Read::ReadData( $self->source );
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

  if ( $option =~ m/MS/ ) {

    # use microsoft date and time notation
    # date number since 1.1.1900
    # time decimal
    $self->{MS} = 1;
  } ## end if ( $option =~ m/MS/ )

  $report->{linecount} = $sheet->{maxrow};

  $self->{mapping} = [];

  foreach my $i ( 1 .. $sheet->{maxrow} ) {

    my $event = $self->rowHandler( $sheet, $i );

    push( $report->{eventList}->@*, $event ) if $event;

  } ## end foreach my $i ( 1 .. $sheet...)

  return $report;
} ## end sub parse

sub rowHandler {
  my ( $self, $sheet, $rowCounter ) = @_;

  my @cell;

  if ( $self->{MS} ) {

    # the MS trick
    @cell = Spreadsheet::Read::cellrow( $sheet, $rowCounter );
  } else {
    @cell = Spreadsheet::Read::row( $sheet, $rowCounter );
  }

  # there must be at least 6 columns
  return unless ( scalar @cell >= 6 );

  # try to find the header row
  if ( !$self->{mapping}->@* && ( join( '', @cell ) =~ /date/i ) ) {

    my $i = 0;

    # find the requested columns and generate a maptable
    my $order = {};
    foreach (@cell) {

      /date/i     && do { $order->{$i} = 0; };
      /time/i     && do { $order->{$i} = 1; };
      /duration/i && do { $order->{$i} = 2; };
      /title/i    && do { $order->{$i} = 3; };
      /short/i    && do { $order->{$i} = 4; };
      /synopsis/i && do { $order->{$i} = 5; };
      /image/i    && do { $order->{$i} = 6; };
      $i += 1;
    } ## end foreach (@cell)
    $self->{mapping} = [ sort { $order->{$a} <=> $order->{$b} } keys $order->%* ];

    return;
  } ## end if ( !$self->{mapping}...)

  return until $self->{mapping}->@*;

  #    0      1      2          3       4       5          6
  my ( $date, $time, $duration, $title, $short, $synopsis, $image ) =
      map { $cell[$_] } $self->{mapping}->@*;
  $time     //= '';
  $duration //= '';
  $title    //= '';
  $short    //= '';
  $synopsis //= '';

  my $start;

  if ( $date =~ m|^(\d+)$| && $self->{MS} ) {

    # integer
    $start = try {
      localtime->strptime( ( $date - 25569 ) * 24 * 60 * 60, "%s" );
    } catch {
      $self->error( "date not in MS format days since 1.1.1900 in row %i [%s]", $rowCounter, $date );
    };

  } elsif ( $date =~ m|^(\d+)\.(\d+)\.(\d\d)$| ) {

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

  if ( $time =~ m/^(\d+)\.(\d+)$/ && $self->{MS} ) {

    # convert MS Excel decimal time format to seconds since midnight
    $start += ONE_MINUTE * sprintf( "%.0f", $time * 24 * 60 );
  } elsif ( $time =~ m/^(\d+)[:\.](\d+)$/ ) {

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

  if ( $duration =~ m/^(\d+)\.(\d+)$/ && $self->{MS} ) {

    # convert MS Excel decimal time format to seconds since midnight
    $duration = sprintf( "%.0f", $duration * 24 * 60 * 60 );
  } elsif ( $duration =~ m/^(\d+):(\d+):(\d+)$/ ) {
    $duration = ( $1 * 60 + $2 ) * 60 + $3;
  } elsif ( $duration =~ m/^(\d+)$/ ) {
    $duration = $1;
  } else {
    $self->error( "duration not valid in row %i: %s", $rowCounter, $duration );
    return;
  }

  # build event
  my $event = {
    start    => $start->epoch,
    duration => $duration,
    title    => $title,
    subtitle => $short,
    synopsis => $synopsis,
  };

  $event->{image} = $image if $image;

  return $event;
} ## end sub rowHandler

=head1 AUTHOR

This software is copyright (c) 2022-2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
