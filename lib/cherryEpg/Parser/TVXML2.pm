package cherryEpg::Parser::TVXML2;

use 5.024;
use utf8;
use Moo;
use Try::Tiny;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.12';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $option)

 Do the file processing and return standard hash.

 The XMLTV file is first processed and only the program with "channel id" equal $parserOption is extracted.
 Then the result is parsed by the XML parser.
 If $parserOption is not defined, the complete file is parsed by the XML parser.

  <?xml version="1.0" encoding="UTF-8"?>
  <tv generator-info-name="tv">
  <channel id="channel_id">
    <display-name lang="en">the human friendly name</display-name>
  </channel>
  <programme start="20220306233000 +0000" stop="20220307003000 +0000" channel="channel_id">
    <title lang="en">Gospel Mix</title>
    <desc lang="en">We profile various gospel artists and showcase their musical talents.</desc>
    <rating system="GB">
      <value>Family</value>
    </rating>
  </programme>
  </tv>

 The time can be given as "start/stop" or "start/end".
 Timezone offset is tolerrant to "+0000" and "+00:00".

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $handler = TVXML2Handler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  # get the content
  my $source = $self->load();

  # extract by channel_id == $option
  $source = $self->extract( $source, $option ) if $option && $option ne '';

  my $content = join( '', $source->@* );

  # run the XML parser
  try {
    $parser->parse( Source => { String => $content } );
  } catch {
    my $error = shift;
    $error =~ s/^\s*(.*)\s*$/$1/;
    $self->error($error);
  };

  return $report;
} ## end sub parse

=head3 extract( $list, $option)

 Extract channel by $option from list of lines.
 Return reference to array of selected lines.

=cut

sub extract {
  my ( $self, $list, $option ) = @_;
  my @content;
  my $current;

  for ( $list->@* ) {
    s/^\N{BOM}//;
    if (/^<\?xml.*/) {

      # save the header
      push( @content, $_ );
    } elsif (/<tv/) {

      # save the header
      push( @content, $_ );
    } elsif (/<\/tv/) {

      # save the header
      push( @content, $_ );
    } elsif (m|<channel.+id="(.+?)"><display-name>(.+?)</display-name>.*</channel>|) {
      if ( $1 eq $option ) {
        push( @content, $_ );
      }
    } elsif (/<channel.+id="(.+?)">/) {
      if ( $1 eq $option ) {
        $current = $1;
        push( @content, $_ );
      } else {
        $current = undef;
      }
    } elsif (/<display-name.*>(.+)<\/display-name/) {
      push( @content, $_ ) if $current;
    } elsif (m|<programme.+channel="(.+?)">.*</programme>|) {

      if ( $1 eq $option ) {
        push( @content, $_ );
      }
    } elsif (/<programme.+channel="(.+?)"/) {
      if ( $1 eq $option ) {
        $current = $1;
        push( @content, $_ );
      } else {
        $current = undef;
      }
    } elsif ( m|</programme>| or m|</channel>| ) {
      push( @content, $_ ) if $current;
      $current = undef;
    } elsif ($current) {

      # just add line to buffer
      push( @content, $_ );
    }
  } ## end for ( $list->@* )

  return \@content;
} ## end sub extract

package TVXML2Handler;
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

  $self->{report} = $self->{'_parser'}->{output};
  push( $self->{report}{eventList}->@*, $self->{eventList}->@* );
  push( $self->{report}{errorList}->@*, $self->{errorList}->@* );
} ## end sub end_document

sub decode_timestamp {
  my ( $self, $t ) = @_;

  return if !$t;
  $t =~ s/://;
  try {
    Time::Piece->strptime( $t, "%Y%m%d%H%M%S %z" )->epoch;
  };
} ## end sub decode_timestamp

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} eq 'programme' ) {
    my $event = {};

    # save start and stop
    # ISO 8601
    $event->{start} = $self->decode_timestamp( $element->{Attributes}{start} );

    # stop can be also end
    $event->{stop} = $self->decode_timestamp( $element->{Attributes}{stop} )
        // $self->decode_timestamp( $element->{Attributes}{end} );

    $self->{currentEvent} = $event;
  } ## end if ( $element->{Name} ...)

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

  push( $self->{errorList}->@*, sprintf( shift, @_ ) );
}

sub addEvent {
  my $self  = shift;
  my $event = $self->{currentEvent};

  # check if all event data is complete and valid
  my @missing;
  push( @missing, "start" ) unless $event->{start};
  push( @missing, "title" ) unless $event->{title};

  if (@missing) {
    $self->_error( "missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  # push to final array
  push( $self->{eventList}->@*, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
