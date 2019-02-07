package Protocol::Redis::hiredis;

use strict;
use warnings;
use Carp 'croak';
use FFI::Platypus;
use FFI::Platypus::Record;
use Alien::hiredis;

use parent 'Protocol::Redis';

use constant {
  REDIS_ERR => -1,
  REDIS_OK  => 0,
};

use constant {
  REDIS_ERR_IO       => 1,
  REDIS_ERR_EOF      => 3,
  REDIS_ERR_PROTOCOL => 4,
  REDIS_ERR_OOM      => 5,
  REDIS_ERR_OTHER    => 2,
};

use constant {
  REDIS_REPLY_STRING  => 1,
  REDIS_REPLY_ARRAY   => 2,
  REDIS_REPLY_INTEGER => 3,
  REDIS_REPLY_NIL     => 4,
  REDIS_REPLY_STATUS  => 5,
  REDIS_REPLY_ERROR   => 6,
};

our $VERSION = '0.001';

our @CARP_NOT = qw(FFI::Platypus);

package
  Protocol::Redis::hiredis::Record::Reader;
FFI::Platypus::Record::record_layout
  int           => 'err',
  'string(128)' => 'errstr',
  pointer       => 'buf',
  size_t        => 'pos',
  size_t        => 'len',
  size_t        => 'maxbuf';

package
  Protocol::Redis::hiredis::Record::Reply;
FFI::Platypus::Record::record_layout
  int         => 'type',
  'long long' => 'integer',
  size_t      => 'len',
  pointer     => 'str',
  size_t      => 'elements',
  pointer     => 'element';

package Protocol::Redis::hiredis;

my $ffi = FFI::Platypus->new(lib => [Alien::hiredis->dynamic_libs]);

$ffi->type('record(Protocol::Redis::hiredis::Record::Reader)' => 'redisReader');
$ffi->type('record(Protocol::Redis::hiredis::Record::Reply)' => 'redisReply');

$ffi->attach_cast('cast_redisReader', 'opaque' => 'redisReader');
$ffi->attach_cast('cast_redisReply', 'opaque' => 'redisReply');
$ffi->attach_cast('cast_string_ptr', 'string' => 'opaque');

$ffi->attach(redisReaderCreate => [] => 'opaque');
$ffi->attach(redisReaderFree => ['opaque'] => 'void');
$ffi->attach(redisReaderFeed => ['opaque', 'opaque', 'size_t'] => 'int', sub {
  my ($xsub, $reader, $str) = @_;
  my $ptr = cast_string_ptr($str);
  unless ($xsub->($reader, $ptr, length($str)) == REDIS_OK) {
    croak _reader_error($reader);
  }
});
$ffi->attach(redisReaderGetReply => ['opaque', 'opaque*'] => 'int', sub {
  my ($xsub, $reader) = @_;
  my $array_ptr;
  unless ($xsub->($reader, \$array_ptr) == REDIS_OK) {
    croak _reader_error($reader);
  }
  return $array_ptr;
});
$ffi->attach(freeReplyObject => ['opaque'] => 'void');

sub parse {
  my ($self, $str) = @_;
  redisReaderFeed($self->_reader, $str);
  while (defined(my $reply = redisReaderGetReply($self->_reader))) {
    my $reply_obj = _unwrap_reply($reply);
    freeReplyObject($reply);
    if (defined(my $cb = $self->{_hiredis_message_cb})) {
      $self->$cb($reply_obj);
    } else {
      push @{$self->{_hiredis_messages}}, $reply_obj;
    }
  }
}

sub get_message { shift @{$_[0]{_hiredis_messages}} }

sub on_message {
  my ($self, $cb) = @_;
  $self->{_hiredis_message_cb} = $cb;
}

sub _reader { $_[0]{_hiredis_reader} ||= redisReaderCreate() }

sub _reader_error {
  my ($reader) = @_;
  my $reader_obj = cast_redisReader($reader);
  return $reader_obj->err == REDIS_ERR_IO ? $! : $reader_obj->errstr;
}

my %type_symbol = (
  REDIS_REPLY_STRING()  => '$',
  REDIS_REPLY_ARRAY()   => '*',
  REDIS_REPLY_INTEGER() => ':',
  REDIS_REPLY_NIL()     => '$',
  REDIS_REPLY_STATUS()  => '+',
  REDIS_REPLY_ERROR()   => '-',
);

sub _unwrap_reply {
  my ($reply) = @_;
  my $reply_obj = cast_redisReply($reply);
  my $type = $reply_obj->type;
  my $data;
  if ($type == REDIS_REPLY_STATUS or $type == REDIS_REPLY_ERROR or $type == REDIS_REPLY_STRING) {
    my $str_len = $reply_obj->len;
    $data = $ffi->cast('opaque', "string($str_len)", $reply_obj->str);
  } elsif ($type == REDIS_REPLY_INTEGER) {
    $data = $reply_obj->integer;
  } elsif ($type == REDIS_REPLY_ARRAY) {
    if (my $num_elements = $reply_obj->elements) {
      my $elements = $ffi->cast('opaque', "opaque[$num_elements]", $reply_obj->element);
      $data = [map { _unwrap_reply($_) } @$elements];
    } else {
      $data = [];
    }
  }
  return {type => $type_symbol{$type}, data => $data};
}

sub DESTROY {
  my $self = shift;
  my $reader = delete $self->{_hiredis_reader};
  redisReaderFree($reader) if defined $reader;
}

1;

=head1 NAME

Protocol::Redis::hiredis - hiredis based parser compatible with Protocol::Redis

=head1 SYNOPSIS

  use Protocol::Redis::hiredis;
  my $redis = Protocol::Redis::hiredis->new(api => 1);

  $redis->parse("+foo\r\n");
  my $message = $redis->get_message;

=head1 DESCRIPTION

This module uses the L<hiredis|https://github.com/redis/hiredis> reply parsing
API via L<libffi|FFI::Platypus> to implement a faster parsing interface for
L<Protocol::Redis>. See L<Protocol::Redis> for usage documentation.

This is a low level parsing module, if you are looking to use Redis in Perl,
try L<Redis>, L<Redis::hiredis>, or L<Mojo::Redis>.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book <dbook@cpan.org>

=head1 CREDITS

Thanks to Sergey Zasenko <undef@cpan.org> for the original L<Protocol::Redis>
and defining the API.

Thanks to David Leadbeater <dgl@dgl.cx> for the inspiration to use C<hiredis>.

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2019 by Dan Book.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 SEE ALSO

L<Protocol::Redis::XS>
