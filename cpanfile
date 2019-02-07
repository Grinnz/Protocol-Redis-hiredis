requires 'perl' => '5.008001';
requires 'parent';
requires 'Alien::hiredis';
requires 'FFI::Platypus';
requires 'Protocol::Redis';
test_requires 'Protocol::Redis::Test';
test_requires 'Test::More' => '0.88';
configure_requires 'Alien::Base::Wrapper';
configure_requires 'Alien::hiredis';
