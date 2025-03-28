package cherryEpg::Parser::SportTVXML;

use 5.024;
use utf8;
use Moo;
use Try::Tiny;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.23';

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
  my ( $self, $channel ) = @_;
  my $report = $self->{report};

  my $handler = SportTVXMLHandler->new();
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

  # now we have multiple channels, let's select the requested one
  if ( defined $channel ) {

    # select by parser option
    if ( $report->{channel}{$channel} ) {
      $report->{eventList} = $report->{channel}{$channel}{eventList};
      $report->{option}    = $channel;
      delete $report->{channel};
    } else {
      $self->error("incorrect channel selection");
    }
  } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 1 ) {

    # if there is just a single channel we asume it's the right one
    my $channel = ( values( %{ $report->{channel} } ) )[0];
    $report->{eventList} = $channel->{eventList};
    delete $report->{channel};
  } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 0 ) {
    $self->error("no valid events");
  } else {
    $self->error("missing channel selection after parser");
  }

  return $report;
} ## end sub parse

package SportTVXMLHandler;
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

  if ( $element->{Name} =~ /oddaja/i ) {
    $self->{currentEvent} = {};
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

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /oddaja/i && do {

      # add only events of selected prog.
      $self->addEvent();
      return;
    };
    /num/i && do {
      $event->{channel} = $value;
      return;
    };
    /title1/ && do {
      $event->{title1} = $value if $value ne "";
      return;
    };
    /title2/ && do {
      $event->{title2} = $value if $value ne "";
      return;
    };
    /kategorija/i && do {
      $event->{kategorija} = $value;
      return;
    };
    /id/ && $value =~ m/^\d+$/ && do {
      $event->{id} = $value & 0xffff;
      return;
    };
    /date/ && do {
      if ( $value =~ m/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/ ) {
        my $start = localtime->strptime( $value, "%Y-%m-%d %H:%M:%S" );
        $event->{start} = $start->epoch;
      } else {
        $self->_error( "Incorrect date format [" . $value . "] in line " . $self->{linecount} );
      }
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
  push( @missing, "title" )
      unless ( defined $event->{title1} || defined $event->{title2} );
  push( @missing, "channel" ) unless defined $event->{channel};

  if ( scalar @missing > 0 ) {
    $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  # combine the titles
  if ( defined $event->{title1} ) {

    $event->{title} = $event->{title1};
    if ( defined $event->{title2} ) {
      if ( $event->{title} ne "" ) {
        $event->{title} .= ": " . $event->{title2};
      }
    }
  } else {
    $event->{title} = $event->{title2};
  }

  $event->{subtitle} = $event->{kategorija} || "";

  my $channel = $event->{channel};
  delete $event->{channel};
  delete $event->{title2};
  delete $event->{title1};
  delete $event->{kategorija};

  # push to final array
  push( @{ $self->{channel}{$channel}{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2019-2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
