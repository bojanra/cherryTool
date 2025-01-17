package cherryEpg::Parser::CanalPlusXLSX;

=head1 NOTICE

This package depends on the package L<Spreadsheet-ParseXLSX> which is not part of the regular cherryEPG 
installation and needs to be installed by running:

  cpanm Spreadsheet::ParseXLSX

Following additional packages will be installed:

  CryptX
  Graphics::ColorUtils
  XML::Twig
  Spreadsheet::ParseXLSX

=cut

use 5.024;
use utf8;
use Moo;
use Spreadsheet::ParseXLSX;
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

$parserOption are currently ignored.

Time/date is parsed and ingested with reference local timezone of the linux system.

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $parser = Spreadsheet::ParseXLSX->new;

  my $eBook = try {
    $parser->parse( $self->source );
  };

  if ( !$eBook ) {
    $self->error("Spreadsheet format not supported!");
    return $report;
  }

  # take the first sheet
  my $sheet = $eBook->worksheet(0);

  if ( !$sheet ) {
    $self->error("No sheet found!");
    return $report;
  }

  my ( $rowMin, $rowMax ) = $sheet->row_range();

  # row by row
  foreach my $row ( $rowMin .. $rowMax ) {

    my $event;

    # we asume the order
    # Date, Time, Duration, Title, Short, Synopsis
    # 0     1     2         3      4      5

    my ( $date, $time, $duration, $title, $short, $synopsis ) = map {
      try { $sheet->get_cell( $row, $_ )->unformatted() }
    } 0 .. 5;

    next if $date =~ /date/i;

    if ( $date !~ m|^\d+/\d+/\d+$| ) {
      $self->error( "incorrect date format in row %i [%s]", $row + 1, $date );
      next;
    }

    if ( $time !~ m|^\d+:\d+$| ) {
      $self->error( "incorrect starttime format in row %i [%s]", $row + 1, $time );
      next;
    }

    $event->{start} = try {
      localtime->strptime( $date . ' ' . $time, "%d/%m/%Y %H:%M" )->epoch;
    } catch {
      $self->error( "date/time parsing error in row %i [%s]", $row + 1, $date . ' ' . $time );
      next;
    };

    if ( $duration =~ m/^(\d+):(\d+)$/ ) {
      $event->{duration} = ( $1 * 60 + $2 ) * 60;
    } else {
      $self->error( "duration not valid in row %i [%s]", $row + 1, $duration );
      next;
    }

    if ( $title eq '' ) {
      $self->error( "missing title in row %i", $row + 1 );
      next;
    }

    $event->{title}    = $title;
    $event->{subtitle} = $short;
    $event->{synopsis} = $synopsis;

    push( $report->{eventList}->@*, $event );
  } ## end foreach my $row ( $rowMin .....)

  return $report;
} ## end sub parse


=head1 AUTHOR

This software is copyright (c) 2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
