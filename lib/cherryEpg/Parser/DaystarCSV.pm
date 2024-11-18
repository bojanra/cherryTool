package cherryEpg::Parser::DaystarCSV;

use 5.024;
use utf8;
use Moo;
use Spreadsheet::Read qw( row ReadData);
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

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

  # start from 3th row
  foreach my $rowCounter ( 3 .. $sheet->{maxrow} ) {

    my (
      # get cells from row
      # A          B                    C                 D         E
      # Start Date Schedule Start Time  Schedule End Time Duration  Program Title
      $date, $startTime, undef, $duration, $title,

      # F              G                    H                     I
      # Episode Title  Parental Rating ID   Parental Rating Name  Category ID
      $subtitle, $parental, undef, undef,

      # J              K                  L                M        N
      # Category Name  Sub Category Name  Sub Category ID  Synopsis Year of Production
      undef, undef, undef, $synopsis, $productionYear,

      # O       P         Q                       R
      # Actors  Custom 5  Repeat Program/Episode  Synopsis 2
      undef, undef, undef, $synopsis2
        )
        = Spreadsheet::Read::row( $sheet, $rowCounter );

    # skip rows without date and first row
    next if !defined $date;

    my ( $year, $month, $day, $hour, $min );

    # convert date in different formats
    if ( $date =~ m|^(\d+)/(\d+)/(\d{4})$| ) {

      # convert from 11/17/2012   month/day/year
      # or 03.05.2016
      $year  = $3;
      $month = $1;
      $day   = $2;
    } else {
      $self->error("Unknown date format [$rowCounter] $date");
      next;
    }

    # extract time ftom $startTime
    if ( $startTime =~ m/^(\d+):(\d+) (AM|PM)$/ ) {
      $hour = $1;
      $min  = $2;
      $hour += 12 if $hour != 12 && $3 eq 'PM';
      $hour = 0   if $hour == 12 && $3 eq 'AM';
    } else {
      $self->error("Unknown time format [$rowCounter] $startTime");
      next;
    }

    my $start = try {
      gmtime->strptime( "$year-$month-$day $hour:$min", "%Y-%m-%d %H:%M" );
    } catch {
      $self->error( "date/time parsing error in row %i [%s]", $rowCounter, "$year-$month-$day $hour:$min" );
    };

    next unless $start;

    #    utf8::decode($title);

    # build event
    my $event = {
      start    => $start->epoch,
      title    => $title,
      duration => $duration * 60,
    };

    if ( defined $subtitle && $subtitle ne "" ) {
      $event->{subtitle} = $subtitle;
    }

    if ( defined $synopsis && $synopsis ne "" ) {
      $synopsis =~ s/\n/ /gs;
      $event->{synopsis} = $synopsis;
    } ## end if ( defined $synopsis...)

    if ( defined $synopsis2 && $synopsis2 ne "" ) {
      $synopsis2 =~ s/\n/ /gs;
      $event->{synopsis} .= ' ' . $synopsis2;
    } ## end if ( defined $synopsis2...)

    if ( defined $year && $year > 1900 ) {
      $event->{synopsis} .= ' ' . $year;
    }

    # push to array
    push( $report->{eventList}->@*, $event );
  } ## end foreach my $rowCounter ( 3 ...)

  return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
