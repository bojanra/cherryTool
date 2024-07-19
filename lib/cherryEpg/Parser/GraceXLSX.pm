package cherryEpg::Parser::GraceXLSX;

use 5.024;
use utf8;
use Moo;
use Spreadsheet::Read qw( row ReadData);
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.32';

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

  # walk over all sheets
  foreach my $sheet ( $eBook->@* ) {

    # skip system sheet
    next unless $sheet->{label};

    foreach my $i ( 1 .. $sheet->{maxrow} ) {

      my $event = $self->rowHandler( $sheet, $i );

      push( $report->{eventList}->@*, $event ) if $event;
    } ## end foreach my $i ( 1 .. $sheet...)
  } ## end foreach my $sheet ( $eBook->...)

  # if ( !$sheet ) {
  #   $self->error("No sheet found!");
  #   return $report;
  # }
  #
  return $report;
} ## end sub parse

sub rowHandler {
  my ( $self, $sheet, $rowCounter ) = @_;
  my $label = $sheet->{label};

  #    A      B           C     D        E       F          G
  my (
    $rawDate, $startTime, undef, $duration, $title, $provider, $description,

    # H         I        J     K         L      M      N        O
    $program, $season, $num, $episode, undef, $game, $rating, $year
      )
      = Spreadsheet::Read::row( $sheet, $rowCounter );

  return if $rawDate eq "Date";

  if ( $rawDate !~ m|,\s(\d+\s\w+\s\d+)$| ) {
    $self->error( "incorrect date format in row %i of sheet '%s' [%s]", $rowCounter, $label, $rawDate );
    return;
  }

  my $date = $1;

  if ( $startTime =~ m|^(\d+:\d+)$| ) {

    # 14:36
    $date .= " " . $1 . ":00";
  } elsif ( $startTime =~ m|^(\d\.\d+)$| || $startTime =~ m|^(\d)$| ) {

    # 0.46 -> HH:MM:SS
    my $f     = $1 + 0.000000000000001;
    my $hour  = $f * 24;
    my $total = int( $hour * 60 * 60 );
    $hour = int($hour);
    my $min    = int( $total / 60 );
    my $second = $total % 60;
    $min = $min % 60;

    $date .= " $hour:$min:$second";
  } else {
    $self->error( "incorrect starttime format in row %i of sheet '%s' [%s]", $rowCounter, $label, $startTime );
    return;

  }

  my $start = try {
    gmtime->strptime( $date, "%d %b %Y %H:%M:%S" );
  } catch {
    $self->error( "date/time parsing error in row %i of sheet '%s' [%s]", $rowCounter, $label, $date );
  };

  return unless $start;

  my $event = {
    start    => $start->epoch,
    title    => $title,
    synopsis => $description,
    subtitle => "$provider $season/$num",
  };

  # we assume that input is real age
  $event->{parental_rating} = $1 if $rating =~ m|-(\d+)$|;

  if ( $duration =~ m/^(\d+):(\d+):(\d+)$/ ) {

    # HH:MM:SS
    $event->{duration} = ( $1 * 60 + $2 ) * 60 + $3;
  } elsif ( $duration =~ m|^(\d\.\d+)$| ) {
    my $f = $1 + 0.000000000000001;
    $event->{duration} = int( $f * 24 * 60 * 60 );
  } else {
    $self->error( "duration not valid in row %i of sheet '%s'[%s]", $rowCounter, $label, $duration );
  }

  return $event;
} ## end sub rowHandler

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
