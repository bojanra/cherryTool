package cherryEpg::Parser::MiTVHTML;

use 5.024;
use utf8;
use HTML::Entities;
use HTML::Parser;
use HTTP::Tiny;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.18';

our $web     = 'https://mi.tv';    # used for subpage grabing
our $timeout = 4;                  # timeout for grabing subpages
our $logger;

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Parse the file and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
  my ( $self, $parserOption ) = @_;
  my $report = $self->{report};

  # not very elegant but required for tracing outside of this object
  $logger = $self->{logger};

  my $parser = HTML::Parser->new( api_version => 3 );

  # this is used for depth counting
  $parser->{level} = 0;

  $parser->{offset}       = 0;
  $parser->{xChangeTitle} = 0;
  $parser->{getEnglish}   = 0;

  # use the parser option as offset, exchange of title and subtitle (X), grabbing of english title (E)
  # e.g.
  # +4,X    add 4 hours and exchange title<->subtitle
  # -3      subtract 3 hours, no exchange
  # 0,X     just exchange
  # 0,E     grab subpages (url) for each event
  # -3,XE   subtract, exchange and grab
  if ( $parserOption && $parserOption =~ /^([+-]?\d+)(,[xe]+)?$/i ) {
    $parser->{offset} = $1 * ONE_HOUR;
    if ($2) {
      my $extended = $2;
      $parser->{xChangeTitle} = $extended =~ m/x/i ? 1 : 0;
      $parser->{getEnglish}   = $extended =~ m/e/i ? 1 : 0;
    }
  } ## end if ( $parserOption && ...)

  $parser->{text} = undef;

  $parser->{eventList} = [];
  $parser->{errorList} = [];

  # get date from file name
  if ( $self->{source} =~ /(\d{4}-\d{2}-\d{2})(_[+-]?\d+)?$/ ) {
    $parser->{date} = $1;
  } else {
    $self->error("filename contains no date");
    return $report;
  }

  $parser->handler( start => \&_start, "self, tagname, attr" );
  $parser->handler( text  => \&_text,  "self, text" );
  $parser->handler( end   => \&_end,   "self, tagname" );

  $parser->unbroken_text(1);

  if ( open( my $fh, "<:utf8", $self->{source} ) ) {
    $self->logger->trace( "parse " . $self->{source} );

    $parser->parse_file($fh);
    close($fh);

    $report->{eventList} = $parser->{eventList};
    $report->{errorList} = $parser->{errorList};
  } else {
    $self->error("error opening file: $!");
  }

  return $report;
} ## end sub parse

sub _start {
  my ( $self, $tagname, $attr ) = @_;

  for ( $self->{level} ) {
    $_ == 1 && $tagname eq 'a' && $attr->{class} && $attr->{class} eq 'program-link' && do {
      $self->{start}    = undef;
      $self->{title}    = '';
      $self->{subtitle} = '';
      $self->{synopsis} = '';
      $self->{url}      = $attr->{href};
      $self->{level}    = 2;
      return;
    };
    $_ == 2 && $tagname eq 'span' && $attr->{class} && $attr->{class} eq 'time' && do {
      $self->{level} = 3;
      return;
    };
    $_ == 4 && $tagname eq 'h2' && do {
      $self->{level} = 5;
      return;
    };
    $_ == 6 && $tagname eq 'span' && $attr->{class} && $attr->{class} eq 'sub-title' && do {
      $self->{level} = 7;
      return;
    };
    $_ == 8 && $tagname eq 'p' && $attr->{class} && $attr->{class} eq 'synopsis' && do {
      $self->{level} = 9;
      return;
    };
    $tagname eq 'ul' && $attr->{class} && $attr->{class} =~ /broadcasts/ && do {
      $self->{level} = 1;
      return;
    };
  } ## end for ( $self->{level} )
} ## end sub _start

sub _text {
  my ( $self, $text ) = @_;

  $text =~ s/^\s+//g;
  $self->{text} = $text;

} ## end sub _text

sub _end {
  my ( $self, $tagname ) = @_;

  for ( $self->{level} ) {
    $_ == 3 && $tagname eq 'span' && do {

      # find start time
      if ( $self->{text} =~ /^(\d+):(\d+)([ap]m)?$/ ) {
        my $hour = $1;
        my $min  = $2;
        my $pm   = $3 && $3 eq 'pm' ? 12 : 0;
        if ( $pm && $hour < 12 ) {
          $hour += $pm;
        }
        $self->{start} = localtime->strptime( $self->{date} . "$hour:$min", "%Y-%m-%d %H:%M" );
        $self->{level} = 4;
      } else {
        push( @{ $self->{errorList} }, "Incorrect time format [" . $self->{text} . "]" );
        $self->{level} = 1;
      }
      return;
    };
    $_ == 5 && $tagname eq 'h2' && do {
      $self->{title} = decode_entities( $self->{text} );
      $self->{level} = 6;
      return;
    };
    $_ == 7 && $tagname eq 'span' && do {
      $self->{subtitle} = decode_entities( $self->{text} );
      $self->{level}    = 8;
      return;
    };
    $_ == 9 && $tagname eq 'p' && do {
      $self->{synopsis} = decode_entities( $self->{text} );
      $self->{level}    = 10;
      return;
    };
    $_ == 10 && $tagname eq 'li' && do {
      _addEvent($self);
      $self->{level} = 1;
    };
  } ## end for ( $self->{level} )
} ## end sub _end

sub _addEvent {
  my ($self) = @_;

  # use the offset
  if ( $self->{offset} ) {
    $self->{start} += $self->{offset};
  }

  # correct date because of TV counting 6-6
  if ( $self->{last} && $self->{start} < $self->{last} ) {
    $self->{start} += ONE_DAY;
  }

  $self->{last} = $self->{start};

  # exchange subtitle and title
  if ( !$self->{xChangeTitle} ) {
    ( $self->{title}, $self->{subtitle} ) = ( $self->{subtitle}, $self->{title} );
  }

  # get english title from subpage url and use as title
  if ( $self->{url} && $self->{getEnglish} ) {
    my $englishTitle = grabSubpage( $self->{url} );
    if ($englishTitle) {
      $self->{title} = $englishTitle;
    }
  } ## end if ( $self->{url} && $self...)

  # Add the event
  my $event = {
    start    => $self->{start}->epoch,
    title    => $self->{title},
    subtitle => $self->{subtitle},
    synopsis => $self->{synopsis},
  };

  push( @{ $self->{eventList} }, $event );

} ## end sub _addEvent

sub grabSubpage {
  my ($path) = @_;

  my $url = $web . $path;

  my $response = try {
    HTTP::Tiny->new( timeout => $timeout )->get($url);
  };

  if ( !$response->{success} ) {
    $logger->trace("grab [$url] failed");
    return;
  }

  utf8::decode( $response->{content} );

  $logger->trace("parsing [$url]");
  my $parser = HTML::Parser->new( api_version => 3 );

  $parser->handler( text => \&_text, "self, text" );
  $parser->handler( end  => \&__end, "self, tagname" );

  $parser->utf8_mode(0);
  $parser->parse( $response->{content} );

  return $parser->{title};
} ## end sub grabSubpage

sub __end {
  my ( $self, $tagname ) = @_;

  $self->{dt} = decode_entities( $self->{text} ) if ( $tagname eq 'dt' );
  if ( $tagname eq 'dd' ) {
    if ( $self->{dt} eq "Título original:" ) {
      $self->{title} = decode_entities( $self->{text} );
    }
    $self->eof;
  } ## end if ( $tagname eq 'dd' )
} ## end sub __end

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
