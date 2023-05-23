package cherryEpg::Parser::SynapseTSV;

use 5.024;
use utf8;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.11';

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

  my @content = try {
    open( my $fh, '<:encoding(UTF-8)', $self->{source} ) || return;

    # open( my $fh, '<:encoding(UTF-8)', $self->{source} ) || return;
    return <$fh>;
  };

  if ( !@content ) {
    $self->error("File empty");
    return $report;
  }

  my $rowCounter = 0;
  foreach (@content) {
    $rowCounter += 1;

    my $event;
    my ( $date, $time, $duration, $title, $synopsis ) = split( /\t/, $_ );

    $event->{start} = try {
      localtime->strptime( $date . ' ' . $time, "%d-%m-%Y %H:%M:%S" )->epoch;
    };

    if ( $duration =~ m/^(\d+):(\d+):(\d+)$/ ) {
      $event->{duration} = ( $1 * 60 + $2 ) * 60 + $3;
    } else {
      $self->error( "duration not valid in row %i: %s", $rowCounter, $duration // '' );
    }
    $event->{title}    = $title;
    $event->{synopsis} = $synopsis;

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" ) unless defined $event->{start};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
      $self->error( "Missing or incorrect input data in line %i: %s", $rowCounter, join( ' ', @missing ) );
      next;
    }

    push( @{ $report->{eventList} }, $event );
  } ## end foreach (@content)

  return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2023 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
