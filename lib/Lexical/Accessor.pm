use 5.008003;
use strict;
use warnings;

use Eval::TypeTiny ();
use Exporter::Tiny ();

package Lexical::Accessor;

use Carp qw( carp croak );
use Hash::Util::FieldHash::Compat qw( fieldhash );
use Scalar::Util qw( blessed reftype );

BEGIN {
	*HAS_SUB_NAME = eval { require Sub::Name } ? sub(){1} : sub(){0};
};

our $AUTHORITY = 'cpan:TOBYINK';
our $VERSION   = '0.001';
our @EXPORT    = qw/ lexical_has /;
our @ISA       = qw/ Exporter::Tiny /;

fieldhash( our %FIELDS );

sub _generate_lexical_has : method
{
	my $me = shift;
	my (undef, undef, $export_opts) = @_;
	
	return sub { $me->lexical_has($export_opts, @_) };
}

my $uniq = 0;
sub lexical_has : method
{
	my $me = shift;
	my $export_opts = ref($_[0]) eq 'HASH' ? shift(@_) : {};
	my ($name, %opts) = (@_%2) ? @_ : (undef, @_);
	
	# Massage %opts
	$opts{_export} = $export_opts;
	$opts{package} = $export_opts->{into} if defined($export_opts->{into}) && !ref($export_opts->{into});
	$me->_canonicalize_opts($name, ++$uniq, \%opts);
	
	my @return;
	my $is = $opts{is};
	
	if (ref $opts{clearer})
	{
		${ $opts{clearer} } = $me->_lexical_clearer($name, $uniq, \%opts);
	}
	
	if (ref $opts{predicate})
	{
		${ $opts{predicate} } = $me->_lexical_predicate($name, $uniq, \%opts);
	}
	
	if ($opts{reader} or $is eq 'ro' or $is eq 'rwp')
	{
		my $reader = $me->_lexical_reader($name, $uniq, \%opts);
		${ $opts{reader} } = $reader if ref $opts{reader};
		push @return, $reader if ($is eq 'ro' or $is eq 'rwp');
	}
	
	if ($opts{writer} or $is eq 'rwp')
	{
		my $writer = $me->_lexical_writer($name, $uniq, \%opts);
		${ $opts{writer} } = $writer if ref $opts{writer};
		push @return, $writer if $is eq 'rwp';
	}
	
	if ($opts{accessor} or $is eq 'rw' or not defined $is)
	{
		my $accessor = $me->_lexical_accessor($name, $uniq, \%opts);
		${ $opts{accessor} } = $accessor if ref $opts{accessor};
		push @return, $accessor;
	}
	
	wantarray ? @return : $return[0];
}

sub _canonicalize_opts : method
{
	my $me = shift;
	my ($name, $uniq, $opts) = @_;
	
	$opts->{is} ||= 'bare';
	
	croak("Delegations are not supported yet") if $opts->{handles};
	croak("Weakening is not supported yet") if $opts->{weak_ref};
	
	for (qw/ clearer predicate /)
	{
		!$opts->{$_}
			or ref($opts->{$_}) eq 'SCALAR'
			or croak("Invalid $_; expected $_ a SCALAR ref");
	}
	
	for (qw/ reader writer accessor /)
	{
		!$opts->{$_}
			or ref($opts->{$_}) eq 'SCALAR'
			or $opts->{$_} eq '1'
			or croak("Invalid $_; expected a SCALAR ref or '1'");
	}
	
	if (defined $opts->{init_arg})
	{
		croak("Invalid init_arg; private attributes cannot be initialized in the constructor");
	}
	
	if ($opts->{required})
	{
		croak("Invalid required; private attributes cannot be initialized in the constructor");
	}
	
	if (defined $opts->{default} and not ref $opts->{default})
	{
		my $value = $opts->{default};
		$opts->{default} = sub { $value };
	}
	
	if (defined $opts->{default} and ref $opts->{default} ne 'CODE')
	{
		croak("Invalid default; expected a CODE ref");
	}
	
	if (defined $opts->{lazy} and not $opts->{lazy})
	{
		croak("Invalid lazy; private attributes cannot be eager");
	}
	
	if (my $does = $opts->{does})
	{
		$opts->{isa} ||= sub {
			blessed($_[0]) && $_[0]->DOES($does)
				or croak("$_[0] doesn't do the $does role");
		};
	}
	
	if (defined $opts->{isa} and not ref $opts->{isa})
	{
		my $type_name = $opts->{isa};
		eval { require Type::Utils }
			or croak("Missing requirement; type constraint strings require Type::Utils");
		
		$opts->{isa} = $opts->{package}
			? Type::Utils::dwim_type($type_name, for => $opts->{package})
			: Type::Utils::dwim_type($type_name);
	}
	
	if (ref $opts->{builder})
	{
		my $code = $opts->{builder};
		defined($name) && defined($opts->{package})
			or croak("Invalid builder; expected method name as string");
		
		my $qname = "$opts->{package}\::_build_$name";
		$me->_exporter_install_sub(
			"_build_$name",
			{},
			$opts->{_export},
			HAS_SUB_NAME ? Sub::Name::subname($qname, $code) : $code,
		);
	}
	
	if (defined $opts->{trigger} and not ref $opts->{trigger})
	{
		my $method_name = $opts->{trigger};
		$opts->{trigger} = sub { my $self = shift; $self->$method_name(@_) };
	}
}

sub _inline_to_coderef : method
{
	my $me = shift;
	my ($method_type, $code, $name, $uniq, $opts) = @_;
	
	my $src  = sprintf(q[sub { %s }], $code);
	my $desc = defined($name)
		? sprintf('lexical %s for %s', $method_type, $name)
		: sprintf('lexical %s', $method_type);
	
	my $coderef = Eval::TypeTiny::eval_closure(
		source      => $src,
		environment => $opts->{inline_environment},
		description => $desc,
	);
	
	HAS_SUB_NAME && $opts->{package} && defined($name)
		? Sub::Name::subname("$opts->{package}\::__LEXICAL__[$name]", $coderef)
		: $coderef
}

sub _lexical_clearer : method
{
	my $me = shift;
	
	$me->_inline_to_coderef(
		clearer => $me->_inline_lexical_clearer(@_),
		@_,
	);
}

sub _inline_lexical_clearer : method
{
	my $me = shift;
	sprintf(
		q[ delete(%s) ],
		$me->_inline_lexical_access(@_),
	);
}

sub _inline_lexical_access : method
{
	my $me = shift;
	my ($name, $uniq, $opts) = @_;
	sprintf(
		q[ $Lexical::Accessor::FIELDS{$_[0]}{%d} ],
		$uniq,
	);
}

sub _lexical_predicate : method
{
	my $me = shift;
	
	$me->_inline_to_coderef(
		predicate => $me->_inline_lexical_predicate(@_),
		@_,
	);
}

sub _inline_lexical_predicate : method
{
	my $me = shift;
	sprintf(
		q[ exists(%s) ],
		$me->_inline_lexical_access(@_),
	);
}

sub _inline_lexical_get : method
{
	my $me = shift;
	my ($name, $uniq, $opts) = @_;
	
	my $get = $me->_inline_lexical_access(@_);
	
	if ($opts->{auto_deref})
	{
		$get = sprintf(
			q[ do { my $x = %s; wantarray ? (ref($x) eq 'ARRAY' ? @$x : ref($x) eq 'HASH' ? %$x : $x ) : $x } ],
			$get,
		);
	}
	
	return $get;
}

sub _inline_lexical_default : method
{
	my $me = shift;
	my ($name, $uniq, $opts) = @_;
	
	if ($opts->{lazy})
	{
		my $get = $me->_inline_lexical_access(@_);
		
		if ($opts->{default})
		{
			$opts->{inline_environment}{'$default'} = \($opts->{default});
			
			return sprintf(
				q[ %s = $default->($_[0]); ],
				$get,
			);
		}
		elsif (defined $opts->{builder})
		{
			return sprintf(
				q[ %s = $_[0]->%s; ],
				$get,
				$opts->{builder},
			);
		}
	}
	
	return '';
}

sub _lexical_reader : method
{
	my $me = shift;
	
	$me->_inline_to_coderef(
		reader => $me->_inline_lexical_reader(@_),
		@_,
	);
}

sub _inline_lexical_reader : method
{
	my $me = shift;
	
	join('',
		$me->_inline_lexical_default(@_),
		$me->_inline_lexical_get(@_),
	);
}

sub _lexical_writer : method
{
	my $me = shift;
	
	$me->_inline_to_coderef(
		writer => $me->_inline_lexical_writer(@_),
		@_,
	);
}

sub _inline_lexical_writer : method
{
	my $me = shift;
	my $get = $me->_inline_lexical_access(@_);
	
	sprintf(
		'my $val = %s; %s; %s; %s = $val;',
		$me->_inline_lexical_type_coercion('$_[1]', @_),
		$me->_inline_lexical_type_assertion('$val', @_),
		$me->_inline_lexical_trigger('$val', $get, @_),
		$get,
	);
}

sub _lexical_accessor : method
{
	my $me = shift;
	
	$me->_inline_to_coderef(
		accessor => $me->_inline_lexical_accessor(@_),
		@_,
	);
}

sub _inline_lexical_accessor : method
{
	my $me = shift;
	my $get = $me->_inline_lexical_access(@_);
	
	sprintf(
		'if (@_ > 1) { my $val = %s; %s; %s; %s = $val }; %s',
		$me->_inline_lexical_type_coercion('$_[1]', @_),
		$me->_inline_lexical_type_assertion('$val', @_),
		$me->_inline_lexical_trigger('$val', $get, @_),
		$get,
		$me->_inline_lexical_get(@_),
	);
}

sub _inline_lexical_type_coercion : method
{
	my $me = shift;
	my ($var, $name, $uniq, $opts) = @_;
	
	my $coercion = $opts->{coerce} or return $var;
	
	unless (ref $coercion)
	{
		my $type = $opts->{isa};
		
		if (blessed($type) and $type->can('coercion'))
		{
			$coercion = $type->coercion;
		}
		elsif (blessed($type) and $type->can('coerce'))
		{
			$coercion = sub { $type->coerce(@_) };
		}
		else
		{
			croak("Invalid coerce; type constraint cannot be probed for coercion");
		}
		
		unless (ref $coercion)
		{
			carp("Invalid coerce; type constraint has no coercion");
			return $var;
		}
	}
	
	if ( blessed($coercion)
	and $coercion->can('can_be_inlined')
	and $coercion->can_be_inlined 
	and $coercion->can('inline_coercion') )
	{
		return $coercion->inline_coercion($var);
	}
	
	if ( blessed($coercion)
	and $coercion->can('coerce') )
	{
		$opts->{inline_environment}{'$coercion'} = \$coercion;
		return sprintf('$coercion->coerce(%s)', $var);
	}
	
	$opts->{inline_environment}{'$coercion'} = \$coercion;
	return sprintf('$coercion->(%s)', $var);
}

sub _inline_lexical_type_assertion : method
{
	my $me = shift;
	my ($var, $name, $uniq, $opts) = @_;
	
	my $type = $opts->{isa} or return '';
	
	if ( blessed($type)
	and $type->can('can_be_inlined')
	and $type->can_be_inlined 
	and $type->can('inline_assert') )
	{
		return $type->inline_assert($var);
	}
	
	if ( blessed($type)
	and $type->can('assert_valid') )
	{
		$opts->{inline_environment}{'$type'} = \$type;
		return sprintf('$type->assert_valid(%s)', $var);
	}
	
	if ( blessed($type)
	and $type->can('check')
	and $type->can('get_message') )
	{
		$opts->{inline_environment}{'$type'} = \$type;
		return sprintf('$type->check(%s) or Carp::croak($type->get_message(%s))', $var, $var);
	}
	
	$opts->{inline_environment}{'$type'} = \$type;
	return sprintf('$type->(%s)', $var);
}

sub _inline_lexical_trigger : method
{
	my $me = shift;
	my ($new, $old, $name, $uniq, $opts) = @_;
	
	my $trigger = $opts->{trigger} or return '';
	
	$opts->{inline_environment}{'$trigger'} = \$trigger;
	return sprintf('$trigger->($_[0], %s, %s)', $new, $old);
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

Lexical::Accessor - true private attributes for Moose/Moo/Mouse

=head1 SYNOPSIS

   my $accessor = lexical_has identifier => (
      is       => 'rw',
      isa      => Int,
      default  => sub { 0 },
   );
   
   # or...
   lexical_has identifier => (
      is       => 'rw',
      isa      => Int,
      default  => sub { 0 },
      accessor => \$accessor,
   );
   
   # later...
   say $self->$accessor;     # says 0
   $self->$accessor( 1 );    # setter
   say $self->$accessor;     # says 1

=head1 DESCRIPTION

Lexical::Accessor generates coderefs which can be used as methods to
access private attributes for objects.

The private attributes are stored inside-out, and do not add any
accessors to the class' namespace, so are completely invisible to any
outside code, including any subclasses. This gives your attribute
complete privacy: subclasses can define a private (or even public)
attribute with the same name as your private one and they will not
interfere with each other.

Private attributes can not be initialized by L<Moose>/L<Moo>/L<Mouse>
constructors, but you can safey initialize them inside a C<BUILD> sub.

=head2 C<< lexical_has $name?, %options >>

This module exports a function L<lexical_has> which acts much like
Moose's C<has> function, but sets up a private (lexical) attribute
instead of a public one.

Because lexical attributes are stored inside-out, the C<$name> is
completely optional; however a name is recommended because it allows
better error messages to be generated.

The L<lexical_has> function supports the following options:

=over

=item C<< is >>

Moose/Mouse/Moo-style C<ro>, C<rw>, C<rwp> and C<lazy> values are
supported. These control what sort of coderef is returned by the
C<lexical_has> function itself.

   my $reader            = lexical_has "foo" => (is => "ro");
   my $accessor          = lexical_has "foo" => (is => "rw");
   my ($reader, $writer) = lexical_has "foo" => (is => "rwp");

If generating more than one method it is probably clearer to pass in
scalar references to the C<reader>, C<writer>, etc methods instead.

=item C<< reader >>, C<< writer >>, C<< accessor >>, C<< predicate >>,
C<< clearer >>

These accept scalar references. The relevent coderefs will be plonked
into them:

   my ($get_foo, $set_foo);
   lexical_has foo => (
      reader      => \$get_foo,
      writer      => \$set_foo,
   );

=item C<< default >>, C<< builder >>, C<< lazy >>

=item C<< isa >>

=item C<< does >>

=item C<< coerce >>

=item C<< trigger >>

=item C<< auto_deref >>

=item C<< init_arg >>, C<< required >>

=item C<< weak_ref >>, C<< handles >>

=back

=head1 BUGS

Please report any bugs to
L<http://rt.cpan.org/Dist/Display.html?Queue=Lexical-Accessor>.

=head1 SEE ALSO

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2013 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

