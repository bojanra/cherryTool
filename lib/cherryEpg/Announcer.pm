package cherryEpg::Announcer;

use 5.024;
use utf8;
use Moo::Role;
use Path::Class;
use Time::Local;
use YAML::XS;

has 'announcer'     => ( is => 'lazy', );
has 'announcerFile' => ( is => 'lazy', );

sub _build_announcerFile {
  my ($self) = @_;

  return file( $self->config->{basedir}, 'announcer.yml' );
}

sub _build_announcer {
  my ($self) = @_;

  my $m = $self->announcerLoad();
  return $m;
} ## end sub _build_announcer

=head3 announcerSave( )

Save the current announcer configuration to file.
Return 1 on success.

=cut

sub announcerSave {
  my ( $self, $announcer ) = @_;

  return 0 unless $announcer;

  $YAML::XS::QuoteNumericStrings = 0;

  if ( YAML::XS::DumpFile( $self->announcerFile, $announcer ) ) {
    $self->{announcer} = $announcer;
    return 1;
  } else {
    return 0;
  }
} ## end sub announcerSave

=head3 announcerLoad( )

Read the current announcer configuration from file.
Return setting.

=cut

sub announcerLoad {
  my ($self) = @_;

  if ( -e $self->announcerFile ) {
    my $a = YAML::XS::LoadFile( $self->announcerFile );
    if ( ref $a eq 'HASH' ) {
      $self->{announcer} = $a;
      return $a;
    }
  } ## end if ( -e $self->announcerFile)

  # return empty
  return {
    present => {
      text    => "",
      publish => 0
    },
    following => {
      text    => "",
      publish => 0
    }
  };
} ## end sub announcerLoad

=head3 announcerInsert( $following, $event)

Insert the announcer following/present (selected by $following) in
the given $event.

=cut

sub announcerInsert {
  my ( $self, $following, $event ) = @_;

  return unless $event;
  my $x = $self->announcer;

  if ($following) {

    # insert following announcer ?
    $self->_replaceText( $event, $self->announcer->{following}{text} ) if $self->announcer->{following}{publish};
  } else {

    # insert present announcer ?
    $self->_replaceText( $event, $self->announcer->{present}{text} ) if $self->announcer->{present}{publish};
  }

} ## end sub announcerInsert

=head3 _replaceText( $event, $text)

In-place replace the short_event_descriptor text field with $text

=cut

sub _replaceText {
  my ( $self, $event, $text ) = @_;

  foreach my $d ( @{ $event->{descriptors} } ) {

    # search short_event_descriptor
    next if $d->{descriptor_tag} != 0x4d;
    $d->{event_name} = $text;
    return if $d->{descriptor_tag} == 0x4d;
  } ## end foreach my $d ( @{ $event->...})
} ## end sub _replaceText

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
