package cherryEpg::Parser::JunoXLS;

use 5.024;
use utf8;
use Moo;
use Spreadsheet::Read qw( row ReadData);
use Time::Piece;
use Time::Seconds;

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

  foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

    # get cells from row
    #   A      B       C          D       E          F      G
    my (
      $date, $time, $duration, $title, $subtitle, undef, undef,

      #   H      I          J-
      undef, $synopsis, undef
        )
        = Spreadsheet::Read::row( $sheet, $rowCounter );

    # skip rows without date and first row
    next
        if !defined $date
        or $date eq ""
        or $date =~ m/datum/i
        or $date =~ m/date/i;

    my ( $year, $month, $day, $hour, $min, $sec );

    # convert date in different formats
    if ( $date =~ m/^(\d{4})-(\d+)-(\d+)$/ ) {

      # this is o.k. 2013-04-23
      $year  = $1;
      $month = $2;
      $day   = $3;
    } elsif ( $date =~ m/^(\d+)[\/\.](\d+)[\/\.](\d{4})$/ ) {

      # convert from 03/01/2012   day/month/year
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

    # correct TV schedule anomaly in the morning hours
    if ( $start < $last && $hour <= 6 ) {
      $start += ONE_DAY;
    }

    $last = $start;
    utf8::decode($title);

    # build event
    my $event = {
      start    => $start->epoch,
      title    => $title,
      duration => $duration * 60,
    };

    if ( defined $subtitle && $subtitle ne "" ) {
      utf8::decode($subtitle);
      $event->{subtitle} = $subtitle;
    }

    if ( defined $synopsis && $synopsis ne "" ) {
      $synopsis =~ s/\n/ /gs;
      utf8::decode($synopsis);
      $event->{synopsis} = $synopsis;
    }

    # push to array
    push( $report->{eventList}->@*, $event );
  } ## end foreach my $rowCounter ( 1 ...)

  return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
