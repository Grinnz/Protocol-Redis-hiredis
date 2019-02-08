package Protocol::Redis::hiredis;

use strict;
use warnings;
use Carp 'croak';
use FFI::Platypus;
use FFI::Platypus::Buffer;
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

our @CARP_NOT = qw(FFI::Platypus FFI::Platypus::Function);

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

$ffi->attach_cast('cast_redisReader', 'pointer' => 'redisReader');
$ffi->attach_cast('cast_redisReply', 'pointer' => 'redisReply');
$ffi->attach_cast('deref_ptr', 'pointer' => 'pointer*');

$ffi->attach(redisReaderCreate => [] => 'opaque');
$ffi->attach(redisReaderFree => ['opaque'] => 'void');
$ffi->attach(redisReaderFeed => ['opaque', 'pointer', 'size_t'] => 'int', sub {
  my ($xsub, $reader, $str) = @_;
  utf8::downgrade $str; # ensure bytes
  my ($pointer, $size) = scalar_to_buffer $str;
  unless ($xsub->($reader, $pointer, $size) == REDIS_OK) {
    croak _reader_error($reader);
  }
});
$ffi->attach(redisReaderGetReply => ['opaque', 'pointer*'] => 'int', sub {
  my ($xsub, $reader) = @_;
  my $reply_ptr;
  unless ($xsub->($reader, \$reply_ptr) == REDIS_OK) {
    croak _reader_error($reader);
  }
  return undef unless defined $reply_ptr;
  my $reply = _unwrap_reply($reply_ptr);
  freeReplyObject($reply_ptr);
  return $reply;
});
$ffi->attach(freeReplyObject => ['opaque'] => 'void');

my %sizes;
$sizes{$_} = $ffi->sizeof($_) for qw(char int pointer size_t), 'long long';

sub parse {
  my ($self, $str) = @_;
  my $reader = $self->_reader;
  redisReaderFeed($reader, $str);
  while (defined(my $reply = redisReaderGetReply($reader))) {
    if (defined(my $cb = $self->{_hiredis_message_cb})) {
      $self->$cb($reply);
    } else {
      push @{$self->{_hiredis_messages}}, $reply;
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
  my ($reply_ptr) = @_;
  my $reply = cast_redisReply($reply_ptr);
  my $type = $reply->type;
  my $data;
  if ($type == REDIS_REPLY_STATUS or $type == REDIS_REPLY_ERROR or $type == REDIS_REPLY_STRING) {
    $data = buffer_to_scalar $reply->str, $reply->len;
  } elsif ($type == REDIS_REPLY_INTEGER) {
    $data = $reply->integer;
  } elsif ($type == REDIS_REPLY_ARRAY) {
    my $elements = $reply->elements;
    my $start_ptr = $reply->element;
    $data = [];
    foreach my $i (0..($elements-1)) {
      push @$data, _unwrap_reply(${deref_ptr($start_ptr + $i * $sizes{pointer})});
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
