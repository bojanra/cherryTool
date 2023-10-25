package cherryEpg::Parser::TVAnytimeXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.28';

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

  my $handler = TVAnytimeXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  $parser->parse( Source => { SystemId => $self->{source} } );

  return $report;
} ## end sub parse

package TVAnytimeXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Carp qw( croak );

my %content = (
  cartoon     => 0x55,
  documentary => 0x23,
  movie       => 0x10,
  news        => 0x20,
  show        => 0x30,
  sports      => 0x40
);

# First go over ProgramInformationTable and store the elements (event) descriptions.
# Then go over Schedule and map event elements to start/stop data.

sub new {
  my $this  = shift;
  my $class = ref($this) || $this;
  my $self  = {};

  bless( $self, $class );
  return $self;
} ## end sub new

sub start_document {
  my ($self) = @_;

  # temporary program info hash
  $self->{programInfo} = {};

  # this will be the events
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

  if ( $element->{Name} eq 'ProgramInformation' ) {

    # take just the id
    if ( $element->{Attributes}{programId} ) {
      $self->{programId}          = $element->{Attributes}{programId};
      $self->{currentProgramInfo} = {};
    }
  } elsif ( $element->{Name} eq 'ScheduleEvent' ) {
    $self->{currentEvent} = {};
  } elsif ( $element->{Name} eq 'Program' ) {
    if ( $element->{Attributes}{crid} ) {
      $self->{currentEvent}{id} = $element->{Attributes}{crid};
    }
  }

  if ( exists $element->{Attributes}{type} ) {
    $self->{type} = $element->{Attributes}{type};
  } else {
    $self->{type} = undef;
  }

  if ( exists $element->{Attributes}{'xml:lang'} ) {
    $self->{lang} = $element->{Attributes}{'xml:lang'};
  } else {
    $self->{lang} = undef;
  }

  if ( exists $element->{Attributes}{length} ) {
    $self->{length} = $element->{Attributes}{length};
  } else {
    $self->{length} = undef;
  }

  $self->{currentData} = "";
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;

  $self->{currentData} .= $element->{Data};
}

sub decodeTime {
  my ( $self, $time ) = @_;

  if ( $time =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+\d{2}):(\d{2})/ ) {

    # 2020-07-20T05:45:00+01:00 -> 2020-07-20T05:45:00+0100
    # remove last doublepoint
    return Time::Piece->strptime( $1 . $2, "%Y-%m-%dT%H:%M:%S%z" )->epoch;
  } elsif ( $time =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z/ ) {

    # 2020-08-31T07:30:00Z
    return Time::Piece->strptime( $1, "%Y-%m-%dT%H:%M:%S" )->epoch;
  } else {
    return;
  }
} ## end sub decodeTime

sub end_element {
  my ( $self, $element ) = @_;
  my $value = $self->{currentData};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /title/i && do {

      if ( exists $self->{type} && $self->{type} && $self->{type} eq 'original' ) {
        $self->{currentProgramInfo}{original} = $value;
      } else {
        $self->{currentProgramInfo}{title} = $value if $self->{lang} =~ /sl/;
      }
      return;
    };
    /synopsis/i && do {
      if ( $self->{length} eq 'long' ) {
        $self->{currentProgramInfo}{synopsis} = $value if $self->{lang} =~ /sl/;
      } else {

#                $self->{currentProgramInfo}{short} = $value if $self->{lang}  =~ /sl/;
      }
      return;
    };
    /keyword/i && do {

      $self->{currentProgramInfo}{keyword} = $value;
      $value = lc($value);
      if ( exists $content{$value} ) {
        $self->{currentProgramInfo}{content}{nibble} = $content{$value};
      }
      return;
    };
    /mpeg7:minimumage/i && do {

      if ( $value >= 4 ) {
        $self->{currentProgramInfo}{parental_rating} = $value;
      }
      return;
    };
    /ProgramInformation/ && do {
      my $id = $self->{programId};
      $self->{programInfo}{$id} = {};

      # copy all info to the hash
      foreach ( keys %{ $self->{currentProgramInfo} } ) {
        $self->{programInfo}{$id}{$_} = $self->{currentProgramInfo}{$_};
      }
      return;
    };
    /ScheduleEvent/ && do {
      my $id = $self->{currentEvent}{id};
      delete $self->{currentEvent}{id};

      # lookup ProgramInformation by $id
      if ( exists $self->{programInfo}{$id} ) {
        foreach ( keys %{ $self->{programInfo}{$id} } ) {
          $self->{currentEvent}{$_} = $self->{programInfo}{$id}{$_};
        }
        $self->addEvent();
      } else {
        $self->_error( "Mapping ScheduleEvent->ProgramInformation failed" . $self->{linecount} );
      }
      return;
    };
    /PublishedEndTime/ && do {
      $self->{currentEvent}{stop} = $self->decodeTime($value);
      return;
    };
    /PublishedStartTime/ && do {
      $self->{currentEvent}{start} = $self->decodeTime($value);
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
  push( @missing, "stop" )  unless defined $event->{stop};
  push( @missing, "title" ) unless defined $event->{title};

  if ( scalar @missing > 0 ) {
    $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  if ( $event->{original} ) {
    $event->{subtitle} = $event->{original};
    delete $event->{original};
  }

  # don't show same info twice
  if ( $event->{subtitle} eq $event->{title} ) {
    $event->{subtitle} = $event->{keyword};
  } else {
    if ( $event->{keyword} ) {
      $event->{subtitle} = $event->{keyword} . ' - ' . $event->{subtitle};
    }
  }

  delete $event->{keyword};
  delete $event->{short};

  # push to final array
  push( @{ $self->{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
