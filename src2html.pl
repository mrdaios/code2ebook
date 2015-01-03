#!/usr/bin/env perl

#use Smart::Comments::JSON '##';
use strict;
use warnings;

use FindBin ();
use File::Temp qw/ :POSIX /;
use Getopt::Long qw( GetOptions :config no_ignore_case);

sub usage ($);
sub process_dir ($);
sub write_src_html ($$);
sub write_index ($$);
sub shell ($);
sub process_tags ($);
sub add_elem_to_hash ($$$);
sub is_tag_array ($);
sub gen_tag_link_list ($$$$);
sub gen_tag_link ($$$$);
sub extract_line_by_lineno ($$$$);
sub process_color_seqs ($);
sub is_included_file ($);

my $charset = 'UTF-8';

my @extra_files;

GetOptions("charset=s",     \$charset,
           "c|color",       \(my $use_colors),
           "h|help",        \(my $help),
           "i|include=s@",  \@extra_files)
   or usage(1);

if ($help) {
    usage(0);
}

my ($tmpfile, $vim_cmd_prefix);
if ($use_colors) {

    my $vimscript = "$FindBin::Bin/syntax-highlight.vim";
    $tmpfile = tmpnam();

    my @vim_cmds = (
        'syntax on',
        "source $vimscript",
        'visual',
        qq{call AnsiHighlight("$tmpfile")},
        'q',
    );

    $vim_cmd_prefix =
        "vim -E -X -R -i NONE -c '" . join(" | ", @vim_cmds). "' -- ";
}

END {
    if (defined $tmpfile && -f $tmpfile) {
        #warn "removing tmp file $tmpfile";
        unlink $tmpfile
            or die "failed to remove file $tmpfile: $!\n";
    }
}

#my %tag_by_files;
#my %tag_by_names;
my %files;
my %func_by_files;
my %global_by_files;
my %type_by_files;
my %macro_by_files;

my $dir = shift or die "No source directory specified.\n";
my $pkg_name = shift or die "No book title specified.\n";

my $cmd = "ctags --list-maps=all";
open my $in, "$cmd|"
    or die "Cannot run command $cmd: $!\n";
while (<$in>) {
    my @exts = split /\s+/;
    shift @exts;
    for my $ext (@exts) {
        if ($ext !~ /\bhtml?$/i) {
            push @extra_files, @exts;
        }
    }
}
close $in;

my $is_included_pattern;

if (@extra_files) {
    for my $f (@extra_files) {
        $f =~ s/\./\\./g;
        $f =~ s/\*/.*?/g;
        if ($f =~ /\|/) {
            $f = "(?:$f)";
        }
    }
    $is_included_pattern = join '|', @extra_files;
    $is_included_pattern = qr/^(?:$is_included_pattern)$/;
    #warn "$is_included_pattern";
}

shell "ctags -n -u --fields=+l --c-kinds=+l -R '$dir'";

my $css;
{
    my $cssfile = "$FindBin::Bin/colorful.css";
    open my $in, $cssfile
        or die "cannot open $cssfile for reading: $!\n";
    $css = do { local $/; <$in> };
    close $in;
}

process_tags("./tags");
process_dir($dir);

sub shell ($) {
    my $cmd = shift;
    #warn "command: $cmd";
    system($cmd) == 0
        or die qq{failed to run command "$cmd": $!\n};
}

sub process_tags ($) {
    my $tagfile = shift;
    open my $in, $tagfile
        or die "cannot open $tagfile for reading: $!\n";
    while (<$in>) {
        next if /^!/;
        if (/^([^\t]+)\s*\t([^\t]+)\t(\d+);"\t(\S+)\tlanguage:(\S+)/) {
            my ($name, $file, $lineno, $kind, $lang) = ($1, $2, $3, $4, $5);
            if ($lang eq 'C++') {
                $lang = 'C';
            }

            if (!exists $files{$file} && $lang ne 'HTML') {
                $files{$file} = $lang;
            }

            #warn "name=$name, file=$file, lineno=$lineno, kind=$kind, lang=$lang\n";
            $name =~ s/^\s+|\s+$//g;
            my $rec = [$name, $file, $lineno, $kind, $lang];
            #add_elem_to_hash(\%tag_by_files, $file, $rec);
            #add_elem_to_hash(\%tag_by_names, $name, $rec);
            if ($kind eq 'f') {
                add_elem_to_hash(\%func_by_files, $file, $rec);

            } elsif ($kind eq 'v') {
                #warn "adding global variable $name at $file:$lineno ...\n";
                add_elem_to_hash(\%global_by_files, $file, $rec);

            } elsif ($kind =~ /^[stug]$/) {
                #warn "adding custom type $name at $file:$lineno ...\n";
                add_elem_to_hash(\%type_by_files, $file, $rec);

            } elsif ($kind eq 'd') {
                add_elem_to_hash(\%macro_by_files, $file, $rec);
            }

        } else {
            die "Unknown tags file line: ", quotemeta($_);
        }
    }
    close $in;
}

sub add_elem_to_hash ($$$) {
    my ($hash, $key, $val) = @_;
    my $old = $hash->{$key};
    if (!defined $old) {
        $hash->{$key} = $val;

    } elsif (ref $old && ref $old eq 'ARRAY' && !ref $old->[0]) {
        $hash->{$key} = [$old, $val];

    } else {
        push @$old, $val;
    }
}

sub process_dir ($) {
    my $dir = shift;
    opendir my $dh, $dir or die "Can't open $dir for reading: $!\n";
    my @items;
    while (my $entity = readdir($dh)) {
        next if $entity =~ /(?:\.(?:swp|swo|bak)|~)$/;
        # entity: $entity
        #warn "entity: $entity";
        my $fname = "$dir/$entity";
        if (exists $files{$fname} || is_included_file($fname)) {
            #warn "Processing file $fname...";
            write_src_html($dir, $entity);
            push @items, [file => $entity];
            next;
        }

        if (-d "$dir/$entity" && $entity !~ /^\./) {
            ## dir: $entity
            my $count = process_dir("$dir/$entity");
            if ($count) {
                push @items, [dir => $entity];
            }
        }
    }
    close $dh;
    if (@items) {
        write_index($dir, \@items);
    }
    return scalar @items;
}

sub is_included_file ($) {
    my $file = shift;
    if (defined $is_included_pattern && -f $file && !-l $file) {
        #warn "testing $file against $is_included_pattern";
        return $file =~ $is_included_pattern;
    }
    #warn "no extra files defined";
    return undef;
}

sub write_src_html ($$) {
    my ($dir, $entity) = @_;

    my $infile = "$dir/$entity";
    #warn "Reading source file $infile\n";

    my $infile2;

    if ($use_colors) {
        shell "$vim_cmd_prefix $infile < /dev/tty > /dev/null";
        $infile2 = $tmpfile;

    } else {
        $infile2 = $infile;
    }

    open my $in, $infile2 or
        die "Can't open $infile2 for reading: $!\n";

    my @lineno_index;
    my $src = '';
    my $pos = 0;
    while (<$in>) {
        $lineno_index[$.] = $pos;
        $src .= $_;
        $pos += length;
    }
    close $in;

    my $preamble = '';

    my $tag = $global_by_files{$infile};
    if (defined $tag) {
        $preamble .= <<_EOC_;
 <h4>Global variables defined</h4>
_EOC_
        gen_tag_link_list(\$preamble, $tag, \$src, \@lineno_index);
    }

    $tag = $type_by_files{$infile};
    if (defined $tag) {
        $preamble .= <<_EOC_;
 <h4>Data types defined</h4>
_EOC_
        gen_tag_link_list(\$preamble, $tag, \$src, \@lineno_index);
    }

    $tag = $func_by_files{$infile};
    if (defined $tag) {
        $preamble .= <<_EOC_;
 <h4>Functions defined</h4>
_EOC_
        gen_tag_link_list(\$preamble, $tag, \$src, \@lineno_index);
    }

    $tag = $macro_by_files{$infile};
    if (defined $tag) {
        $preamble .= <<_EOC_;
 <h4>Macros defined</h4>
_EOC_
        gen_tag_link_list(\$preamble, $tag, \$src, \@lineno_index);
    }

    if ($preamble) {
        $preamble .= <<_EOC_;
 <h4>Source code</h4>
_EOC_
    }

    if ($src =~ /PRETEND TO BE IN Parse::RecDescent NAMESPACE/s) {
        $src = 'Omitted parser file generated automatically by Parse::RecDescent';

    } else {
        for ($src) {
            s/\n\n\n+/\n\n/gs;
            s/[ \t]+\n/\n/gs;
            s/\t/    /gs;
            s/\&/\&amp;/g;
            while (s/  /&nbsp; /gs) {}  # use loop here to accomadate
                                        #  odd numbers of spaces.
            s/</\&lt;/g;
            s/>/\&gt;/g;
            s/"/\&quot;/g;
            # the &#x200c; noise is to work-around a bug in epub + ibooks.
            s{_SRC2KINDLE_L(\d+)_}{<a id="_L$1">&#x200c;</a>}smg;
            s/\n/<br\/>/g;
        }
    }

    if ($use_colors) {
        process_color_seqs(\$src);
    }

    my $outfile = "$dir/$entity.html";
    open my $out, ">$outfile" or
        die "Can't open $outfile for writing: $!\n";
    print $out <<_EOC_;
<html>
 <head>
  <title>$infile - $pkg_name</title>
  <meta http-equiv="Content-Type" content="text/html;charset=UTF-8">
  <style>
$css
  </style>
 </head>
 <body>
  <h3>$infile - $pkg_name</h3>
$preamble
  <code>$src</code>
 </body>
</html>
_EOC_
    close $out;
    warn "Wrote $outfile\n";
}

sub gen_tag_link_list ($$$$) {
    my ($preamble_ref, $tag, $src_ref, $lineno_index) = @_;

    $$preamble_ref .= <<_EOC_;
 <ul>
_EOC_

    if (is_tag_array($tag)) {
        my $tags = $tag;
        @$tags = sort { $a->[0] cmp $b->[0] } @$tags;
        for my $t (@$tags) {
            my $rc = gen_tag_link($preamble_ref, $t, $src_ref, $lineno_index);
            if (!$rc) {
                undef $t;
            }
        }

        for my $t (@$tags) {
            next unless defined $t;
            tag_line_by_lineno($src_ref, $t->[1], $t->[2], $lineno_index);
        }

    } else {
        gen_tag_link($preamble_ref, $tag, $src_ref, $lineno_index);
        tag_line_by_lineno($src_ref, $tag->[1], $tag->[2], $lineno_index);
    }

    $$preamble_ref .= <<_EOC_;
</ul>
_EOC_
}

sub gen_tag_link ($$$$) {
    my ($preamble_ref, $tag, $src_ref, $lineno_index) = @_;
    my $name = $tag->[0];
    my $file = $tag->[1];
    my $lineno = $tag->[2];
    my $kind = $tag->[3];
    my $lang = $tag->[4];
    if ($lang eq 'C' && $name =~ /^[_A-Z]+$/ && $kind eq 'f') {
        # possibly a macro-sugared C function; use the whole line
        $name = extract_line_by_lineno($src_ref, $file, $lineno,
                                       $lineno_index);
        #die "Found line at line $lineno: [$name]";
        if ($name =~ /^\s*case\b.*?:/) {
            return undef;
        }
    }
    $$preamble_ref .= <<_EOC_;
<li><a href="#_L$lineno">$name</a></li>
_EOC_
    return 1;
}

sub extract_line_by_lineno ($$$$) {
    my ($src_ref, $file, $lineno, $lineno_index) = @_;
    my $pos = $lineno_index->[$lineno];
    if (!defined $pos) {
        die "Line $lineno not found in file $file (only seen ",
            scalar(@$lineno), " lines)\n";
    }
    #warn "setting pos to $pos...\n";
    pos $$src_ref = $pos;
    if ($$src_ref =~ /\G[^\n]*/m) {
        my $line = $&;
        #if ($file eq 'src/lib_ffi.c') {
        #warn "$file:$lineno:$pos: [$line]\n";
        #}
        return $line;
    }
}

sub tag_line_by_lineno ($$$$) {
    my ($src_ref, $file, $lineno, $lineno_index) = @_;
    my $pos = $lineno_index->[$lineno];
    if (!defined $pos) {
        die "Line $lineno not found in file $file (only seen ",
            scalar(@$lineno), " lines)\n";
    }
    pos $$src_ref = $pos;
    my $replace = "_SRC2KINDLE_L${lineno}_";
    if ($$src_ref =~ s/\G/$replace/sm) {
        my $offset = length $replace;
        for (my $i = $lineno + 1; 1; $i++) {
            my $pos = $lineno_index->[$i];
            last if !defined $pos;
            $lineno_index->[$i] += $offset;
        }
    }
}

sub is_tag_array ($) {
    my ($t) = @_;
    ref $t && ref $t eq 'ARRAY' && ref $t->[0];
}

sub write_index ($$) {
    my ($dir, $ritems) = @_;
    my $outfile = "$dir/index.html";
    open my $out, ">$outfile" or
        die "Can't open $outfile for writing: $!\n";

    print $out <<_EOC_;
<html>
<head>
 <title>$dir/ - $pkg_name</title>
</head>
<body>
 <h3>$dir/ - $pkg_name</h3>
 <ul>
_EOC_
    for my $item (sort { $a->[1] cmp $b->[1] } @$ritems) {
        my ($type, $entity) = @$item;
        if ($type eq 'file') {
            print $out qq{  <li><a href="$entity.html">$entity</a></li>\n};
        } else {
            print $out qq{  <li><a href="$entity/index.html">$entity/</a></li>\n};
        }
    }
    print $out <<_EOC_;
 </ul>
</body>
</html>
_EOC_
    close $out;
    warn "Wrote $outfile\n";
}

sub process_color_seqs ($) {
    my ($src_ref) = @_;

    my $open;

    $$src_ref =~ s#\x1b\[(\w*);#
        my $name = $1;
        my $out = '';

        if ($open) {
            if (!$name || $name eq 'Normal') {
                undef $open;
                "</span>";

            } else {
                qq{</span><span class="$name">};
            }

        } else {
            if (!$name || $name eq 'Normal') {
                "";

            } else {
                $open = 1;
                qq{<span class="$name">};
            }
        }
     #ge;

     if ($open) {
         $$src_ref .= "</span>";
     }
}

sub usage ($) {
    my $rc = shift;
    my $msg = <<'_EOC_';
src2html.pl [options] dir

Options:
    --charset CHARSET     Specify the charset used by the HTML
                          outputs. Default to UTF-8.

    -c
    --color               Use full colors in the HTMTL outputs.

    -h
    --help                Print this help.

    -i PATTERN
    --include PATTERN     Specify the pattern for extra source code file names
                          to include in the HTML output. Wildcards
                          like * and [] are supported. And multiple occurances
                          of this option are allowed.

Copyright (C) Yichun Zhang (agentzh) <agentzh@gmail.com>.
_EOC_
    if ($rc == 0) {
        print $msg;
        exit(0);
    }

    warn $msg;
    exit($rc);
}
