#!/bin/bash
# Terminal slide presenter
# Splits markdown by # H1 headings, renders heading with toilet+lolcat, body with glow

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <markdown-file>"
    exit 1
fi

INPUT_FILE="$1"
TOILET_FONT="${TOILET_FONT:-pagga}"
TOILET_FONT_H2="${TOILET_FONT_H2:-future}"
VCENTER="${VCENTER:-false}"  # Set to "true" to vertically center content
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR; tput rmcup 2>/dev/null || printf '\033[?1049l'; clear" EXIT

# Split markdown into individual slide files
split_slides() {
    awk -v tmpdir="$TMPDIR" '
    BEGIN {
        slide = 0
        current_file = ""
        in_code_block = 0
    }
    /^```/ {
        # Toggle code block state
        in_code_block = !in_code_block
        if (current_file != "") {
            print $0 >> current_file
        }
        next
    }
    /^# / && !in_code_block {
        if (current_file != "") {
            close(current_file)
        }
        slide++
        current_file = tmpdir "/slide_" slide ".md"
        heading_file = tmpdir "/heading_" slide ".txt"
        print substr($0, 3) > heading_file
        close(heading_file)
        next
    }
    /^## / && !in_code_block {
        # Save H2 headings separately
        if (current_file != "") {
            h2_file = tmpdir "/heading2_" slide ".txt"
            print substr($0, 4) > h2_file
            close(h2_file)
        }
        next
    }
    {
        if (current_file != "") {
            print $0 >> current_file
        }
    }
    END {
        if (current_file != "") {
            close(current_file)
        }
        total_file = tmpdir "/total"
        print slide > total_file
    }
    ' "$INPUT_FILE"
}

split_slides
TOTAL_SLIDES=$(cat "$TMPDIR/total")

# Pre-render all slides
echo "Rendering slides..." >&2
for i in $(seq 1 $TOTAL_SLIDES); do
    cols=$(tput cols)

    # Pre-render H1 heading (with word-wrap)
    if [ -f "$TMPDIR/heading_$i.txt" ]; then
        # Fold at word boundaries before toilet (pagga font is ~4:1 ratio)
        cat "$TMPDIR/heading_$i.txt" | fold -s -w $((cols / 4)) | toilet -f "$TOILET_FONT" -w $cols | lolcat -f > "$TMPDIR/rendered_h1_$i.txt"
        wc -l < "$TMPDIR/rendered_h1_$i.txt" > "$TMPDIR/h1_lines_$i.txt"
    else
        echo "0" > "$TMPDIR/h1_lines_$i.txt"
    fi

    # Pre-render H2 heading with 1-space indent (with word-wrap)
    if [ -f "$TMPDIR/heading2_$i.txt" ]; then
        # Fold at word boundaries before toilet (future font is ~2:1 ratio)
        cat "$TMPDIR/heading2_$i.txt" | fold -s -w $((cols / 2)) | toilet -f "$TOILET_FONT_H2" -w $cols | lolcat -f | sed 's/^/ /' > "$TMPDIR/rendered_h2_$i.txt"
        wc -l < "$TMPDIR/rendered_h2_$i.txt" > "$TMPDIR/h2_lines_$i.txt"
    else
        echo "0" > "$TMPDIR/h2_lines_$i.txt"
    fi

    # Note: We don't pre-render glow because it strips colors when piped
    # Glow will be rendered live in show_slide()
done
echo "Done!" >&2

CURRENT_SLIDE=1

# Enter alternate screen buffer to prevent scrolling
tput smcup 2>/dev/null || printf '\033[?1049h'

show_slide() {
    local slide_num=$1
    local cols=$(tput cols)
    local lines=$(tput lines)

    # Clear screen
    tput clear
    tput cup 0 0

    # Read pre-calculated line counts
    local h1_lines=$(cat "$TMPDIR/h1_lines_$slide_num.txt")
    local h2_lines=$(cat "$TMPDIR/h2_lines_$slide_num.txt")

    # Calculate total heading lines (including blank line after last heading)
    local line_count=0
    if [ $h1_lines -gt 0 ]; then
        line_count=$((line_count + h1_lines))
    fi
    if [ $h2_lines -gt 0 ]; then
        line_count=$((line_count + h2_lines))
    fi
    # Add 1 blank line after headings section
    if [ $h1_lines -gt 0 ] || [ $h2_lines -gt 0 ]; then
        line_count=$((line_count + 1))
    fi

    # Display pre-rendered H1 heading
    if [ -f "$TMPDIR/rendered_h1_$slide_num.txt" ]; then
        cat "$TMPDIR/rendered_h1_$slide_num.txt"
        # Only add blank line if there's no H2 following
        if [ ! -f "$TMPDIR/rendered_h2_$slide_num.txt" ]; then
            echo
        fi
    fi

    # Display pre-rendered H2 heading (no gap after H1)
    if [ -f "$TMPDIR/rendered_h2_$slide_num.txt" ]; then
        cat "$TMPDIR/rendered_h2_$slide_num.txt"
        echo
    fi

    # Render body live with glow (can't pipe - loses colors)
    if [ -f "$TMPDIR/slide_$slide_num.md" ]; then
        # Just render directly, no piping to preserve colors
        # Note: May scroll if content is too long
        glow -w $cols "$TMPDIR/slide_$slide_num.md"
    fi
}

# Navigation
navigate() {
    show_slide $CURRENT_SLIDE

    while true; do
        # Read single character without waiting for enter
        read -rsn1 key

        case "$key" in
            ' ')  # Space
                if [ $CURRENT_SLIDE -lt $TOTAL_SLIDES ]; then
                    CURRENT_SLIDE=$((CURRENT_SLIDE + 1))
                    show_slide $CURRENT_SLIDE
                fi
                ;;
            $'\x1b')  # ESC sequence (arrow keys)
                read -rsn2 key
                case "$key" in
                    '[C')  # Right arrow
                        if [ $CURRENT_SLIDE -lt $TOTAL_SLIDES ]; then
                            CURRENT_SLIDE=$((CURRENT_SLIDE + 1))
                            show_slide $CURRENT_SLIDE
                        fi
                        ;;
                    '[D')  # Left arrow
                        if [ $CURRENT_SLIDE -gt 1 ]; then
                            CURRENT_SLIDE=$((CURRENT_SLIDE - 1))
                            show_slide $CURRENT_SLIDE
                        fi
                        ;;
                esac
                ;;
            'q'|'Q')
                tput rmcup 2>/dev/null || printf '\033[?1049l'
                clear
                exit 0
                ;;
        esac
    done
}

if [ $TOTAL_SLIDES -eq 0 ]; then
    echo "No slides found. Make sure your markdown has # H1 headings."
    exit 1
fi

navigate
