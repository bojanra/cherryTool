package cherryEpg::Parser::CmsXML;

use 5.024;
use utf8;
use Moo;
use Try::Tiny;
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

  my $handler = CmsXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  # get the content
  my $source = $self->load();

  my $content = join( '', $source->@* );

  # remove BOM
  $content =~ s/\x{feff}//sg;

  # run the XML parser
  try {
    $parser->parse( Source => { String => $content } );
  } catch {
    my $error = shift;
    chomp $error;
    $error =~ s/^\s*(.*) at line.*$/$1/;
    $self->error($error);
  };

  return $report;
} ## end sub parse

package CmsXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;
use Carp qw( croak );

# First go over editorialContent and store the elements (event) descriptions.
# Then go over editorialChannel and map event elements to start/stop data.

sub new {
  my $this  = shift;
  my $class = ref($this) || $this;
  my $self  = {};

  bless( $self, $class );
  return $self;
} ## end sub new

sub start_document {
  my ($self) = @_;

  # temporary content hash
  $self->{content} = {};

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

  if ( $element->{Name} eq 'editorialContent' && $element->{Attributes}{providerResourceId} && $element->{Attributes}{name} ) {
    my $id   = $element->{Attributes}{providerResourceId};
    my $name = $element->{Attributes}{name};
    $self->{content}{$id} = $name;
  }

  if ( $element->{Name} eq 'event' ) {
    $self->{currentEvent} = {};

    if ( $element->{Attributes}{name} ) {
      $self->{currentEvent}{title} = $element->{Attributes}{name};
    }
  } ## end if ( $element->{Name} ...)

  if ( $element->{Name} eq 'period' ) {
    if ( $element->{Attributes}{start} && $element->{Attributes}{end} ) {
      $self->{currentEvent}{start} = try {
        gmtime->strptime( $element->{Attributes}{start}, "%Y-%m-%dT%H:%M:%SZ" )->epoch;
      };
      $self->{currentEvent}{stop} = try {
        gmtime->strptime( $element->{Attributes}{end}, "%Y-%m-%dT%H:%M:%SZ" )->epoch;
      };
    } ## end if ( $element->{Attributes...})
  } ## end if ( $element->{Name} ...)

  if ( $element->{Name} eq 'editorialContentRef' && $element->{Attributes}{providerResourceId} ) {
    $self->{currentEvent}{id} = $element->{Attributes}{providerResourceId};
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

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    $_ eq "event" && do {
      if ( exists $self->{currentEvent}{title} ) {

        # use the event title
      } elsif ( exists $self->{currentEvent}{id} && exists $self->{content}{ $self->{currentEvent}{id} } ) {

        # lookup ProgramInformation by $id
        $self->{currentEvent}{title} = $self->{content}{ $self->{currentEvent}{id} };
      }
      $self->addEvent();
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

  delete $event->{id};

  # push to final array
  push( @{ $self->{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
