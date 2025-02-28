package cherryEpg::Parser::TV24HTML;

use 5.024;
use utf8;
use HTML::Entities;
use HTML::Parser;
use Moo;
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.21';

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

  my $parser = HTML::Parser->new( api_version => 3 );

  # this is used for depth counting
  $parser->{level} = 0;

  $parser->{offset} = 0;

  # use the parser option as offset
  if ( $parserOption && $parserOption =~ /^[+-]?\d+$/ ) {
    $parser->{offset} = $parserOption * ONE_HOUR;
  }

  $parser->{text} = undef;

  $parser->{eventList} = [];
  $parser->{errorList} = [];

  # get date from file name
  if ( $self->{source} =~ /(\d{4}-\d{2}-\d{2})$/ ) {
    $parser->{date} = gmtime->strptime( $1, "%Y-%m-%d" );
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

    my $r = $parser->parse_file($fh);
    close($fh);

    $report->{eventList} = $r->{eventList};
    $report->{errorList} = $r->{errorList};
  } else {
    $self->error("error opening file: $!");
  }

  return $report;
} ## end sub parse

sub _start {
  my ( $self, $tagname, $attr ) = @_;

  if ( $tagname eq 'span' ) {
    if ( $attr->{class} and $attr->{class} eq 'time' ) {
      $self->{class} = 'time';
    } elsif ( $attr->{class} and $attr->{class} eq 'desc' ) {
      $self->{class} = 'desc';
    } else {
      $self->{class} = '';
    }
  } elsif ( $tagname eq 'li' ) {
    $self->{event} = {};
  }
  $self->{text} = "";
} ## end sub _start

sub _text {
  my ( $self, $text ) = @_;

  $self->{text} .= $text;

} ## end sub _text

sub _end {
  my ( $self, $tagname ) = @_;

  if ( $tagname eq 'span' and $self->{class} eq 'time' ) {

    if ( $self->{text} =~ /(\d+):(\d+)(a|p)m$/ ) {
      my $hour = $1;
      my $min  = $2;
      my $am   = $3 eq 'a' ? 1 : 0;
      $hour += 12 if $hour != 12 && !$am;
      $hour += 12 if $hour == 12 && $am;

      my $start = $self->{date} + ONE_HOUR * $hour + ONE_MINUTE * $min;

      $start += ONE_DAY if exists $self->{last} && $start < $self->{last};
      $self->{last} = $start;


      $self->{event} = { start => $start->epoch, };
    } else {
      push( @{ $self->{errorList} }, "Incorrect time format [" . $self->{text} . "]" );
    }

  } elsif ( $tagname eq 'span' and $self->{class} eq 'desc' ) {

    $self->{event}{subtitle} = $self->{text};
  } elsif ( $tagname eq 'h3' ) {

    $self->{event}{title} = $self->{text};
  } elsif ( $tagname eq 'p' ) {

    $self->{event}{synopsis} = $self->{text};
  } elsif ( $tagname eq 'li' ) {

    if ( $self->{event}{start} ) {

      # use the offset
      if ( $self->{offset} ) {
        $self->{event}{start} += $self->{offset};
      }

      push( @{ $self->{eventList} }, $self->{event} );
    } ## end if ( $self->{event}{start...})

  } ## end elsif ( $tagname eq 'li' )

} ## end sub _end

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
