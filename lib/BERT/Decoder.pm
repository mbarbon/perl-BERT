package BERT::Decoder;
use strict;
use warnings;

use 5.008;

use Carp 'croak';
use BERT::Constants;
use BERT::Types;

sub new {
    my $class = shift;
    return bless { }, $class;
}

sub decode {
    my ($self, $bert) = @_;
    my $bert_ref = \$bert;

    my $magic = unpack('C', substr $bert, 0, 1);

    croak sprintf('Bad magic number. Expected %d found %d', MAGIC_NUMBER, $magic)
        unless MAGIC_NUMBER == $magic;

    return $self->_extract_any($bert_ref, 1);
}

sub _extract_any {
    my ($self, $bert_ref, $offset) = @_;

    (my $value, $offset) = $self->read_any($bert_ref, $offset);

    $value = $self->extract_complex_type($value)
        if ref $value eq 'BERT::Tuple';

    return [ $value, $self->_extract_any($bert_ref, $offset + 1) ] if $offset < length($$bert_ref);
    return $value;
}

sub extract_complex_type {
    my ($self, $tuple) = @_;

    my @array = @{ $tuple->value };
    return $tuple unless $array[0] eq 'bert';

    if ($array[1] eq 'nil') {
        return undef;
    } elsif ($array[1] eq 'true') {
        return BERT::Boolean->true;
    } elsif ($array[1] eq 'false') {
        return BERT::Boolean->false;
    } elsif ($array[1] eq 'dict') {
        my @dict = map(@{ $_->value }, @{ $array[2] });

        # Someday I should add an option to allow hashref to be returned instead
        return BERT::Dict->new(\@dict);
    } elsif ($array[1] eq 'time') {
        my ($megasec, $sec, $microsec) = @array[2, 3, 4];
        return  BERT::Time->new($megasec * 1_000_000 + $sec, $microsec);
    } elsif ($array[1] eq 'regex') {
        my ($source, $options) = @array[2, 3];
        my $opt = '';
        for (@{ $options }) {
            if    ($_ eq 'caseless')  { $opt .= 'i' }
            elsif ($_ eq 'dotall')    { $opt .= 's' }
            elsif ($_ eq 'extended')  { $opt .= 'x' }
            elsif ($_ eq 'multiline') { $opt .= 'm' }
        }
        return eval "qr/$source/$opt";
    } else {
        croak "Unknown complex type $array[1]";
    }
}

sub read_any {
    my ($self, $bert_ref, $offset) = @_;
    my $value;

    my $type = unpack('C', substr $$bert_ref, $offset, 1);
    $offset++;

    if (SMALL_INTEGER_EXT == $type) {
        return (unpack('C', substr $$bert_ref, $offset, 1), $offset + 1);
    } elsif (INTEGER_EXT == $type) {
        # This should have been unpack('l>a*',...) only and not have extra unpack('l',...)
        # but I don't want to require perl >= v5.10
        my $value = unpack('N', substr $$bert_ref, $offset, 4);
        $value = unpack('l', pack('L', $value));
        return ($value, $offset + 4);
    }
    elsif (FLOAT_EXT == $type) {
        return (unpack('Z31', substr $$bert_ref, $offset, 31), $offset + 31);
    }
    elsif (ATOM_EXT == $type) {
        my $len = unpack('n', substr $$bert_ref, $offset, 2);
        $value = BERT::Atom->new(substr $$bert_ref, $offset + 2, $len);
        return ($value, $offset + 2 + $len);
    }
    elsif (SMALL_TUPLE_EXT == $type) {
        my $len = unpack('C', substr $$bert_ref, $offset, 1);
        (my $array, $offset) = $self->_read_array($bert_ref, $offset + 1, $len);
        return (BERT::Tuple->new($array), $offset);
    }
    elsif (LARGE_TUPLE_EXT == $type) {
        my $len = unpack('N', substr $$bert_ref, $offset, 4);
        (my $array, $offset) = $self->_read_array($bert_ref, $offset + 4, $len);
        return (BERT::Tuple->new($array), $offset);
    }
    elsif (NIL_EXT == $type) {
        return ([], $offset);
    }
    elsif (STRING_EXT == $type) {
        my $len = unpack('n', substr $$bert_ref, $offset, 2);
        return (
            [unpack 'C*', substr $$bert_ref, $offset + 2, $len],
            $offset + 2 + $len
        );
    }
    elsif (LIST_EXT == $type) {
        my $len = unpack('N', substr $$bert_ref, $offset, 4);
        (my $value, $offset) = $self->_read_array($bert_ref, $offset + 4, $len);
        my $type = unpack('C', substr $$bert_ref, $offset, 1);
        croak 'Lists with non NIL tails are not supported'
            unless NIL_EXT == $type;
        return ($value, $offset + 1);
    }
    elsif (BINARY_EXT == $type) {
        my $len = unpack('N', substr $$bert_ref, $offset, 4);
        return (substr($$bert_ref, $offset + 4, $len), $offset + 4 + $len);
    }
    elsif (SMALL_BIG_EXT == $type) {
        my $len = unpack('C', substr $$bert_ref, $offset, 1);
        return $self->_read_bigint($bert_ref, $offset + 1, $len);
    }
    elsif (LARGE_BIG_EXT == $type) {
        my $len = unpack('N', substr $$bert_ref, $offset, 4);
        return $self->_read_bigint($bert_ref, $offset + 4, $len);
    }
    else {
        croak "Unknown type $type";
    }
}

sub _read_bigint {
    my $self = shift;
    my ($bert_ref, $offset, $len) = @_;

    my($sign, @values)  = unpack('CC*', substr $$bert_ref, $offset, $len + 1);

    require Math::BigInt;
    my $i = Math::BigInt->new(0);
    my $value = 0;

    foreach my $item (@values) {
        $value += $item * 256 ** $i++;
    }

    $value->bneg() if $sign != 0;

    return ($value, $offset + 1 + $len);
}

sub _read_array {
    my $self = shift;
    my ($bert_ref, $offset, $len) = @_;
    my @array;
    for my $i (1 .. $len) {
        (my $item, $offset) = $self->read_any($bert_ref, $offset);
        push @array, $item;
    }
    return (\@array, $offset);
}

1;

__END__

=head1 NAME

BERT::Decoder - BERT deserializer

=head1 SYNOPSIS

  use BERT::Decoder;

  my $decoder = BERT::Decoder->new;
  my $data = $decoder->decode($bert);

=head1 DESCRIPTION

This module decodes BERT binaries into Perl data structures.

See the BERT specification at L<http://bert-rpc.org/>.

=head1 METHODS

=over 4

=item $decoder = BERT::Decoder->new

Creates a new BERT::Decoder object.

=item $bert = $decoder->decode($scalar)

Returns the Perl data structure for the given BERT binary. Croaks on error.

=back

=head1 AUTHOR

Sherwin Daganato E<lt>sherwin@daganato.comE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<BERT> L<BERT::Atom> L<BERT::Boolean> L<BERT::Dict> L<BERT::Time> L<BERT::Tuple>

=cut
