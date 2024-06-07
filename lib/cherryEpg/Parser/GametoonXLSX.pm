package cherryEpg::Parser::GametoonXLSX;

use 5.024;
use utf8;
use Moo;
use Spreadsheet::Read qw( row ReadData);
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser::SimpleXLS';

our $VERSION = '0.30';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

sub rowHandler {
  my ( $self, $sheet, $rowCounter ) = @_;

  my @cell = Spreadsheet::Read::row( $sheet, $rowCounter );

  # there must be at least 6 columns
  return unless ( scalar @cell >= 6 );

  map { $_ //= '' } @cell;

  # try to find the header row
  if ( !$self->{mapping}->@* && ( join( '', @cell ) =~ /date/i ) ) {

    # find the requested columns and generate a maptable
    my $order = {};
    my $i     = 0;

    foreach (@cell) {
      /start date/i && do { $order->{$i} = 0; };
      /start time/i && do { $order->{$i} = 1; };
      /end date/i   && do { $order->{$i} = 2; };
      /end time/i   && do { $order->{$i} = 3; };
      /title/i      && do { $order->{$i} = 4; };
      /synopsis/i   && do { $order->{$i} = 5; };
      $i += 1;
    } ## end foreach (@cell)
    $self->{mapping} = [ sort { $order->{$a} <=> $order->{$b} } keys $order->%* ];

    return;
  } ## end if ( !$self->{mapping}...)

  return until $self->{mapping}->@*;

  # map the read fields in the correct order
  #    0      1      2       3       4          5
  my ( $startDate, $startTime, $endDate, $endTime, $title, $synopsis ) =
      map { $cell[$_] } $self->{mapping}->@*;
  $startDate //= '';
  $startTime //= '';
  $endDate   //= '';
  $endTime   //= '';
  $title     //= '';
  $synopsis  //= '';

  my $start = try {
    localtime->strptime( $startDate . ' ' . $startTime, "%Y%m%d %H:%M:%S" );
  } catch {
    $self->error( "start date or time not in format YYYYMMDD hh:mm:ss in row %i [%s %s]", $rowCounter, $startDate, $startTime );
  };

  my $stop = try {
    localtime->strptime( $endDate . ' ' . $endTime, "%Y%m%d %H:%M:%S" );
  } catch {
    $self->error( "end date or time not in format YYYYMMDD hh:mm:ss in row %i [%s %s]", $rowCounter, $endDate, $endTime );
  };

  return unless $stop && $start;

  # build event
  my $event = {
    start    => $start->epoch,
    stop     => $stop->epoch,
    title    => $title,
    synopsis => $synopsis,
  };

  return $event;
} ## end sub rowHandler

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
