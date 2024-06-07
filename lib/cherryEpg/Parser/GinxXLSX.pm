package cherryEpg::Parser::GinxXLSX;

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
  return unless ( scalar @cell >= 8 );

  map { $_ //= '' } @cell;

  # try to find the header row
  if ( !$self->{mapping}->@* && ( join( '', @cell ) =~ /date/i ) ) {

    # find the requested columns and generate a maptable
    my $order = {};
    my $i     = 0;

    foreach (@cell) {
      /date/i     && do { $order->{$i} = 0; };
      /start/i    && do { $order->{$i} = 1; };
      /title/i    && do { $order->{$i} = 2; };
      /comment/i  && do { $order->{$i} = 3; };
      /parental/i && do { $order->{$i} = 4; };
      $i += 1;
    } ## end foreach (@cell)
    $self->{mapping} = [ sort { $order->{$a} <=> $order->{$b} } keys $order->%* ];

    return;
  } ## end if ( !$self->{mapping}...)

  return until $self->{mapping}->@*;

  # map the read fields in the correct order
  #    0      1      2       3       4          5
  my ( $date, $startTime, $title, $synopsis, $parental ) =
      map { $cell[$_] } $self->{mapping}->@*;
  $date      //= '';
  $startTime //= '';
  $title     //= '';
  $synopsis  //= '';

  my $start = try {
    gmtime->strptime( $date . ' ' . $startTime, "%d/%m/%Y %H:%M" );
  } catch {
    $self->error( "date or time not in format DD/MM/YYYY hh:mm in row %i [%s %s]", $rowCounter, $date, $startTime );
  };

  return unless $start;

  # build event
  my $event = {
    start    => $start->epoch,
    title    => $title,
    synopsis => $synopsis,
  };

  # we assume that input is already in descriptor format
  $event->{parental_rating} = $parental + 3 if $parental;

  return $event;
} ## end sub rowHandler

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
