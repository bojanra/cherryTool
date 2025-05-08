package cherryEpg::Parser::VasKanalXLS;

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

  # try to find the header row
  if ( !$self->{mapping}->@* && ( join( '', @cell ) =~ /datum/i ) ) {

    # find the requested columns and generate a maptable
    my $order = {};
    my $i     = 0;

    foreach (@cell) {

      /datum/i     && do { $order->{$i} = 0; };
      /ura/i       && do { $order->{$i} = 1; };
      /naslov/i    && do { $order->{$i} = 2; };
      /podnaslov/i && do { $order->{$i} = 3; };
      /opis/i      && do { $order->{$i} = 4; };
      /voditelji/i && do { $order->{$i} = 5; };
      $i += 1;
    } ## end foreach (@cell)
    $self->{mapping} = [ sort { $order->{$a} <=> $order->{$b} } keys $order->%* ];
    return;
  } ## end if ( !$self->{mapping}...)

  return until $self->{mapping}->@*;

  # map the read fields in the correct order
  #    0      1      2       3       4          5
  my ( $date, $time, $title, $short, $synopsis, $voditelji ) =
      map { $cell[$_] } $self->{mapping}->@*;
  $time      //= '';
  $title     //= '';
  $short     //= '';
  $synopsis  //= '';
  $voditelji //= '';

  my $start;

  #remove spaces
  $date =~ s/\s//g;

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
  } elsif ( $date =~ m|^(\d{4})-(\d+)-(\d+)| ) {

    # yyyy-mm-dd
    $start = try {
      localtime->strptime( $date, "%Y-%m-%d" );
    } catch {
      $self->error( "date not in format YYYY-MM-DD in row %i [%s]", $rowCounter, $date );
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

  if ( $time =~ m/^\s*(\d+)[:\.](\d+)$/ ) {

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

  utf8::decode($synopsis);
  utf8::decode($title);
  utf8::decode($short);

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

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
