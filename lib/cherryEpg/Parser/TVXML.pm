package cherryEpg::Parser::TVXML;

use 5.024;
use utf8;
use Moo;
use Try::Tiny;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.24';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- programme => hash of arrays of events found

The XMLTV format can contain multiple programme schedules.

Please be carefull programme = channel here.

When multiple programme are defined $parserOption should contain a key value e.g.
channel => "htv1.tv.hrt.hr" to select a programme.
If there is only a single programmee defined in the file no channel option is required.

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $handler = TVXMLHandler->new();

  my $parser = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  try {
    $parser->parse( Source => { SystemId => $self->{source} } );
  };

  # now we have multiple channels, let's select the requested one
  if ( defined $option ) {

    # select by parser option
    if ( exists $report->{channel}{$option} ) {
      $report->{eventList} = $report->{channel}{$option}{eventList};
      $report->{option}    = $option;
      delete $report->{channel};
    } else {
      push( @{ $report->{errorList} }, "incorrect channel selection" );
    }
  } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 1 ) {

    # if there is just a single channel we asume it's the right one
    my $channel = ( values( %{ $report->{channel} } ) )[0];
    $report->{eventList} = $channel->{eventList};
    delete $report->{channel};
  } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 0 ) {
    push( @{ $report->{errorList} }, "no valid events" );
  } else {
    push( @{ $report->{errorList} }, "missing channel selection after parser" );
  }

  return $report;
} ## end sub parse

package TVXMLHandler;
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

  # here we will store all program hashes
  $self->{channel} = {};

  # and the possible error list
  $self->{errorList} = [];
} ## end sub start_document

sub end_document {
  my ( $self, $element ) = @_;

  $self->{report} = $self->{'_parser'}->{output};

  # return all built program lists
  $self->{report}{channel}   = $self->{channel};
  $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} eq 'programme' ) {
    my $event = {};

    # save the start and stop FIXME error handwling
    # ISO 8601
    $event->{start} = try {
      if ( exists $element->{Attributes}{start} ) {
        Time::Piece->strptime( $element->{Attributes}{start}, "%Y%m%d%H%M%S %z" )->epoch;
      } else {
        return undef;
      }
    };

    # workaround to use attribute stop or end !!!
    $event->{stop} = try {
      if ( exists $element->{Attributes}{stop} ) {
        Time::Piece->strptime( $element->{Attributes}{stop}, "%Y%m%d%H%M%S %z" )->epoch;
      } elsif ( exists $element->{Attributes}{end} ) {
        Time::Piece->strptime( $element->{Attributes}{end}, "%Y%m%d%H%M%S %z" )->epoch;
      } else {
        return undef;
      }
    };

    $event->{channel} = $element->{Attributes}{channel};

    $self->{currentEvent} = $event;
  } elsif ( $element->{Name} =~ /title/i ) {

  }

  # store current language
  if ( $element->{Attributes}{lang} ) {
    $self->{currentLang} = $element->{Attributes}{lang};
  } else {
    $self->{currentLang} = '';
  }

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
  my $lang  = $self->{currentLang};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /programme/i && do {

      # add the event to the list
      $self->addEvent();
      return;
    };
    $_ eq "title" && do {

      $event->{title} = $value;
      return;
    };
    /sub-title/ && do {

      $event->{subtitle} = $value;
      return;
    };
    /desc/i && do {

      $event->{synopsis} = $value;
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
  push( @missing, "start" )   unless $event->{start};
  push( @missing, "title" )   unless defined $event->{title};
  push( @missing, "channel" ) unless defined $event->{channel};

  if ( scalar @missing > 0 ) {
    $self->_error( "missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  my $channel = $event->{channel};
  delete $event->{channel};

  # push to final array
  push( @{ $self->{channel}{$channel}{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2019-2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
