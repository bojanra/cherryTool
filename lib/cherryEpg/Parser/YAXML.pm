package cherryEpg::Parser::YAXML;

use 5.024;
use utf8;
use Moo;
use Try::Tiny;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.18';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => hash of arrays of events found

=cut

sub parse {
  my ( $self, $parserOption ) = @_;
  my $report = $self->{report};

  my $handler = YAXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  try {
    $parser->parse( Source => { SystemId => $self->{source} } );
  } catch {
    my ($error) = @_;
    if ( $error =~ m|(.+) at /| ) {
      $self->error($1);
    } else {
      $self->error($error);
    }
  };

  if ($parserOption) {
    my ($offset) = split( /[\|,]/, $parserOption );

    # offset can be
    # +hhmm
    # -hhmm
    #  hhmm
    # +hh:mm
    # -hh:mm
    #  hh:mm
    if ( $offset =~ m/^\s*([+-]?\d{1,4})$/ ) {
      $offset += 0;
      my $sign = $offset < 0 ? -1 : 1;
      $offset *= $sign;

      $offset = $offset % 100 + int( $offset / 100 ) * 60;
      $offset *= $sign;
    } elsif ( $offset =~ m/^\s*(?<pm>[+-])?(?<hour>\d{1,2}):(?<minute>\d{1,2})$/ ) {
      $offset = $+{minute} + 60 * $+{hour};
      $offset *= ( $+{pm} // 0 eq '-' ? -1 : 1 );
    } else {
      $offset = undef;
      $self->error("parser option not valid: $parserOption");
    }

    if ($offset) {
      foreach my $event ( $report->{eventList}->@* ) {
        $event->{start} += $offset * 60;
        $event->{stop}  += $offset * 60 if $event->{stop};
      }
    } ## end if ($offset)
  } ## end if ($parserOption)

  return $report;
} ## end sub parse

package YAXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Try::Tiny;
use Carp qw( croak );

sub new {
  my $this  = shift;
  my $class = ref($this) || $this;
  my $self  = {};

  bless( $self, $class );
  return $self;
} ## end sub new

sub start_document {
  my ($self) = @_;

  # this will be the list of events
  $self->{eventList} = [];

  # and the possible error list
  $self->{errorList} = [];
} ## end sub start_document

sub end_document {
  my ( $self, $element ) = @_;

  $self->{report}            = $self->{'_parser'}->{output};
  $self->{report}{eventList} = $self->{eventList};
  $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} =~ /item/i ) {
    my $event;

    $self->{eventcount} += 1;

    $event->{start} = try {
      if ( exists $element->{Attributes}{start} ) {
        Time::Piece->strptime( $element->{Attributes}{start}, "%Y%m%d%H%M %z" )->epoch;
      } else {
        return undef;
      }
    };

    # workaround to use attribute stop or end !!!
    $event->{stop} = try {
      if ( exists $element->{Attributes}{stop} ) {
        Time::Piece->strptime( $element->{Attributes}{stop}, "%Y%m%d%H%M %z" )->epoch;
      } else {
        return undef;
      }
    };

    $self->{currentEvent} = $event;
  } ## end if ( $element->{Name} ...)

  $self->{currentData} = "";
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;

  $self->{currentData} .= $element->{Data};
}

sub end_element {
  my ( $self, $element ) = @_;
  my $value = $self->{currentData};
  my $event = $self->{currentEvent};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /item/i && do {

      # add the event to the list
      $self->addEvent();
      return;
    };
    $_ eq "title" && do {

      $event->{title} = $value;
      return;
    };
    /description/i && do {

      $event->{subtitle} = $value;
      return;
    };
  } ## end SWITCH: for ( $element->{Name} )
  return;
} ## end sub end_element

sub set_document_locator {
  my ( $self, $params ) = @_;
  $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
  my $self = shift;

  push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

sub addEvent {
  my $self  = shift;
  my $event = $self->{currentEvent};

  # check if all event data is complete and valid
  my @missing;
  push( @missing, "start" ) unless defined $event->{start};
  push( @missing, "title" ) unless defined $event->{title};

  if ( scalar @missing > 0 ) {
    $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  # push to final array
  push( @{ $self->{eventList} }, $event );

  return 1;
} ## end sub addEvent
1;

=head1 AUTHOR

This software is copyright (c) 2023 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

