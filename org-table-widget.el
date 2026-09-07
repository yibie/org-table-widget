;;; org-table-widget.el --- Display Org tables as responsive pixel-aligned widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 yibie

;; Author: yibie <https://github.com/yibie>
;; Assisted-by: OpenAI Codex
;; Maintainer: yibie <https://github.com/yibie>
;; URL: https://github.com/yibie/org-table-widget
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6") (textui "0.8.0"))
;; Keywords: outlines, wp, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `org-table-widget-mode' shows every Org table in the buffer as a
;; block widget whose columns are aligned in pixels rather than in
;; characters.  Cells that mix CJK text, emoji, inline code and
;; proportional fonts stay aligned, long cells wrap inside their
;; column, and the table reflows when the window width changes.
;;
;; The buffer text is never modified.  Each table is covered by an
;; overlay whose `before-string' holds the laid-out widget, so
;; `org-element', export, `#+TBLFM' evaluation and Babel keep seeing
;; the original table.  Moving point into a table removes its widget
;; and reveals the source for ordinary `org-table' editing; moving
;; point out of the table lays it out again.
;;
;; Cell contents are copied from the fontified buffer, so links,
;; emphasis and code markup keep the faces Org gives them.
;;
;; Layout is provided by TextUI (https://github.com/yibie/textui),
;; which lays out block widgets inside ordinary Emacs buffers.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'wid-edit)
(require 'org)
(require 'org-table)
(require 'org-element)

(declare-function textui-layout-widget "textui" (widget width))
(defvar org-table-widget-mode)

;;;; Options and faces

(defgroup org-table-widget nil
  "Display Org tables as responsive pixel-aligned widgets."
  :group 'org
  :prefix "org-table-widget-")

(defcustom org-table-widget-use-unicode-borders t
  "When non-nil, draw table borders with box-drawing characters.
Otherwise use ASCII pipes, plus signs and dashes."
  :type 'boolean)

(defcustom org-table-widget-zebra-stripe t
  "When non-nil, give every second data row the zebra face."
  :type 'boolean)

(defcustom org-table-widget-wrap-columns t
  "When non-nil, wrap cells so the table fits the window width.
When nil, lay every column out at its natural width."
  :type 'boolean)

(defcustom org-table-widget-max-width-fraction 1.0
  "Fraction of the window body width available to a table."
  :type 'number)

(defcustom org-table-widget-relayout-delay 0.15
  "Idle seconds to wait after a window resize before laying tables out.
Resizing a frame by dragging fires many configuration changes in a row;
waiting until they stop produces one relayout instead of one per step.
A value of zero or less relays out immediately."
  :type 'number)

(defcustom org-table-widget-reveal-on-point t
  "When non-nil, show a table's source while point is inside it.
The widget returns as soon as point leaves the table."
  :type 'boolean)

(defcustom org-table-widget-cell-properties
  '(face font-lock-face invisible display mouse-face help-echo keymap
         follow-link htmlize-link org-emphasis)
  "Text properties copied from the buffer into widget cells.
Every other property is dropped so that the widget does not inherit
line prefixes, fontification state or private markers."
  :type '(repeat symbol))

(defface org-table-widget-header
  '((t :inherit bold))
  "Face for header rows.")

(defface org-table-widget-border
  '((t :inherit shadow))
  "Face for borders and rules.")

(defface org-table-widget-zebra
  '((((class color) (background light)) :background "gray95")
    (((class color) (background dark)) :background "gray20")
    (t :inherit highlight))
  "Face for alternating data rows.")

;;;; Pixel measurement

(defconst org-table-widget--measure-x-limit 100000
  "X limit for `window-text-pixel-size' so wide cells are not clipped.")

(defvar-local org-table-widget--char-pixel-cache nil
  "Cons cell (FONT-WIDTH . SPACE-PIXELS) caching the width of a space.")

(defvar-local org-table-widget--measure-cache nil
  "Cons cell (VALIDITY . HASH-TABLE) caching string measurements.
VALIDITY records the fonts the measurements were taken with.")

(defconst org-table-widget--measure-cache-limit 50000
  "Number of cached measurements after which the cache is rebuilt.")

(defun org-table-widget--measure-string (str window)
  "Return the pixel width of STR rendered at the end of WINDOW's buffer.
STR is pinned to `fixed-pitch' so the result does not depend on
`variable-pitch-mode' remapping the default face."
  (let ((str (copy-sequence str)))
    (add-face-text-property 0 (length str) 'fixed-pitch nil str)
    (with-current-buffer (window-buffer window)
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t)
            (buffer-undo-list t)
            (modified (buffer-modified-p))
            (deactivate-mark nil)
            real)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-max))
            (let ((m (point-marker)))
              (set-marker-insertion-type m nil)
              (insert str)
              (put-text-property m (point) 'fontified t)
              (remove-text-properties m (point)
                                      '(line-prefix nil wrap-prefix nil))
              (setq real (car (window-text-pixel-size
                               window m (point)
                               org-table-widget--measure-x-limit)))
              (delete-region m (point))
              (set-marker m nil))))
        (set-buffer-modified-p modified)
        real))))

(defun org-table-widget--char-pixel-width (window)
  "Return the pixel width of one space in WINDOW, cached per buffer."
  (with-current-buffer (window-buffer window)
    (let ((fw (ignore-errors (window-font-width window))))
      (if (and org-table-widget--char-pixel-cache
               (equal fw (car org-table-widget--char-pixel-cache)))
          (cdr org-table-widget--char-pixel-cache)
        (let ((sw (org-table-widget--measure-string " " window)))
          (setq org-table-widget--char-pixel-cache (cons fw sw))
          sw)))))

(defun org-table-widget--measurements (window)
  "Return the measurement cache for WINDOW's buffer.
The cache survives relayouts and is dropped when the window font or
the `fixed-pitch' font changes."
  (with-current-buffer (window-buffer window)
    (let ((validity (list (ignore-errors (window-font-width window))
                          (ignore-errors (face-font 'fixed-pitch)))))
      (unless (and org-table-widget--measure-cache
                   (equal (car org-table-widget--measure-cache) validity)
                   (< (hash-table-count (cdr org-table-widget--measure-cache))
                      org-table-widget--measure-cache-limit))
        (setq org-table-widget--measure-cache
              (cons validity (make-hash-table :test 'equal))))
      (cdr org-table-widget--measure-cache))))

(defmacro org-table-widget--with-cached-measurements (window &rest body)
  "Run BODY with `org-table-widget--measure-string' cached for WINDOW."
  (declare (indent 1))
  (let ((measure (make-symbol "measure"))
        (table (make-symbol "table")))
    `(let* ((,measure (symbol-function 'org-table-widget--measure-string))
            (,table (org-table-widget--measurements ,window)))
       (cl-letf (((symbol-function 'org-table-widget--measure-string)
                  (lambda (string destination)
                    (let* ((key (prin1-to-string string))
                           (cached (gethash key ,table 'missing)))
                      (if (eq cached 'missing)
                          (puthash key (funcall ,measure string destination)
                                   ,table)
                        cached)))))
         ,@body))))

(defun org-table-widget--pixel-budget (width window)
  "Return the pixel budget for a table laid out at WIDTH columns in WINDOW.
WIDTH counts columns of the frame's default font; converting it with
the `fixed-pitch' space width overshoots when the two faces use
different fonts, so the result never exceeds the window's real body
pixel width when WIDTH fills the window."
  (let* ((measured (org-table-widget--measure-string
                    (make-string width ?\s) window))
         (body-pixels (and (window-live-p window)
                           (window-body-width window t)))
         (budget (if (and body-pixels
                          (> body-pixels width)
                          (>= width (window-body-width window)))
                     (min measured body-pixels)
                   measured)))
    (floor (* org-table-widget-max-width-fraction budget))))

;;;; Graphemes and wrapping

(defun org-table-widget--break-after-p (text i)
  "Return non-nil when a line may break after index I in TEXT.
I + 1 must be a valid index.  Breaks are allowed after line-breakable
characters (CJK ideographs, kana, Hangul) unless the next character is
zero-width and must stay attached."
  (and (aref (char-category-set (aref text i)) ?|)
       (> (char-width (aref text (1+ i))) 0)))

(defun org-table-widget--regional-indicator-p (char)
  "Return non-nil when CHAR is a regional-indicator symbol."
  (<= #x1F1E6 char #x1F1FF))

(defun org-table-widget--grapheme-extension-p (char)
  "Return non-nil when CHAR extends the preceding grapheme."
  (or (zerop (char-width char))
      (<= #x1F3FB char #x1F3FF)))

(defun org-table-widget--next-grapheme-end (text start)
  "Return the end of the extended grapheme in TEXT starting at START."
  (let* ((length (length text))
         (end (1+ start)))
    (when (and (org-table-widget--regional-indicator-p (aref text start))
               (< end length)
               (org-table-widget--regional-indicator-p (aref text end)))
      (setq end (1+ end)))
    (while (and (< end length)
                (org-table-widget--grapheme-extension-p (aref text end))
                (not (= (aref text end) #x200D)))
      (setq end (1+ end)))
    (while (and (< end length) (= (aref text end) #x200D))
      (setq end (min length (+ end 2)))
      (while (and (< end length)
                  (org-table-widget--grapheme-extension-p (aref text end))
                  (not (= (aref text end) #x200D)))
        (setq end (1+ end))))
    end))

(defun org-table-widget--grapheme-ends (text start)
  "Return grapheme end positions in TEXT following START."
  (let ((position start)
        ends)
    (while (< position (length text))
      (setq position (org-table-widget--next-grapheme-end text position))
      (push position ends))
    (nreverse ends)))

(defun org-table-widget--fit-end (text start pixels window)
  "Return the longest end of TEXT after START fitting PIXELS in WINDOW."
  (let* ((ends (vconcat (org-table-widget--grapheme-ends text start)))
         (low 0)
         (high (1- (length ends)))
         (best (aref ends 0)))
    (while (<= low high)
      (let* ((mid (/ (+ low high) 2))
             (end (aref ends mid))
             (measured (org-table-widget--measure-string
                        (substring text start end) window)))
        (if (<= measured pixels)
            (setq best end low (1+ mid))
          (setq high (1- mid)))))
    best))

(defun org-table-widget--break-end (text start end)
  "Move END back to a natural break in TEXT without crossing START."
  (let ((scan (1- end))
        break)
    (while (and (> scan start) (not break))
      (when (or (memq (aref text scan) '(?\s ?\t))
                (and (< scan (1- (length text)))
                     (org-table-widget--break-after-p text scan)))
        (setq break (1+ scan)))
      (setq scan (1- scan)))
    (or break end)))

(defun org-table-widget--wrap-pixels (text pixels window)
  "Wrap TEXT into lines no wider than PIXELS in WINDOW."
  (if (or (string-empty-p text)
          (<= (org-table-widget--measure-string text window) pixels))
      (list text)
    (let ((position 0)
          (text-length (length text))
          lines)
      (while (< position text-length)
        (let* ((fit (org-table-widget--fit-end text position pixels window))
               (end (if (< fit text-length)
                        (org-table-widget--break-end text position fit)
                      fit)))
          (push (string-trim-right (substring text position end)) lines)
          (setq position end)
          (while (and (< position text-length)
                      (memq (aref text position) '(?\s ?\t)))
            (setq position (1+ position)))))
      (nreverse lines))))

(defun org-table-widget--longest-token-pixels (text window)
  "Return the pixel width of the widest unbreakable token in TEXT in WINDOW."
  (let ((length (length text))
        (start 0)
        (widest 0))
    (cl-flet ((measure-token (end)
                (when (> end start)
                  (setq widest
                        (max widest
                             (org-table-widget--measure-string
                              (substring text start end) window))))))
      (dotimes (index length)
        (cond
         ((memq (aref text index) '(?\s ?\t))
          (measure-token index)
          (setq start (1+ index)))
         ((and (< index (1- length))
               (org-table-widget--break-after-p text index))
          (measure-token (1+ index))
          (setq start (1+ index)))))
      (measure-token length))
    widest))

;;;; Column widths

(defconst org-table-widget--width-cap-fraction 0.5
  "Fraction of the available width that bounds one column's claims.
Without the cap a single huge cell takes nearly the whole table and
starves the short columns down to one character per line.")

(defun org-table-widget--widths (rows columns pixel-budget boundary-pixels
                                      window)
  "Allocate pixel widths for COLUMNS over ROWS in WINDOW.
ROWS is a list of cell lists; `hline' entries are ignored.
PIXEL-BUDGET includes the BOUNDARY-PIXELS between columns.

Each column claims a minimum (its widest grapheme, or its widest
unbreakable token up to the cap) and a natural width (its widest
cell).  When the natural widths do not fit, the space left after the
minimums is shared in proportion to each column's natural width above
its minimum, capped so one giant cell cannot starve the others."
  (let* ((space-pixels (org-table-widget--char-pixel-width window))
         (base-minimum (+ 1 (* 2 space-pixels)))
         (available (- pixel-budget (* (1+ columns) boundary-pixels)))
         (cap (floor (* org-table-widget--width-cap-fraction available)))
         (minimums (make-list columns base-minimum))
         (natural (make-list columns base-minimum)))
    (dolist (row rows)
      (unless (eq row 'hline)
        (cl-loop for cell in row
                 for column from 0
                 do (let ((cell-pixels
                           (org-table-widget--measure-string cell window))
                          (cluster-maximum 1)
                          (token-maximum
                           (org-table-widget--longest-token-pixels
                            cell window))
                          (start 0))
                      (dolist (end (org-table-widget--grapheme-ends cell 0))
                        (setq cluster-maximum
                              (max cluster-maximum
                                   (org-table-widget--measure-string
                                    (substring cell start end) window)))
                        (setq start end))
                      (setf (nth column natural)
                            (max (nth column natural)
                                 (+ (* 2 space-pixels) cell-pixels)))
                      (setf (nth column minimums)
                            (max (nth column minimums)
                                 (+ (* 2 space-pixels)
                                    (max cluster-maximum
                                         (min token-maximum cap)))))))))
    (let ((natural-total (apply #'+ natural))
          (minimum-total (apply #'+ minimums)))
      (cond
       ((not org-table-widget-wrap-columns) natural)
       ((<= natural-total available) natural)
       ((<= available minimum-total) minimums)
       (t
        (let* ((flexible (- available minimum-total))
               (weights (seq-mapn (lambda (width minimum)
                                    (max 1 (- (min width cap) minimum)))
                                  natural minimums))
               (weight-total (apply #'+ weights))
               (allocated 0)
               widths)
          (cl-loop for weight in weights
                   for minimum in minimums
                   for column from 0
                   for column-width =
                   (if (= column (1- columns))
                       (- available allocated)
                     (+ minimum
                        (floor (* flexible (/ (float weight) weight-total)))))
                   do (setq allocated (+ allocated column-width))
                   do (push column-width widths))
          (nreverse widths)))))))

;;;; Rendering

(defun org-table-widget--pixel-space (pixels)
  "Return an invisible display space occupying PIXELS."
  (if (> pixels 0)
      (propertize "\u200B" 'display `(space :width (,pixels))
                  'org-table-widget-spacing t)
    ""))

(defun org-table-widget--boundary (glyph pixels window)
  "Return GLYPH normalized to PIXELS of horizontal advance in WINDOW."
  (let ((glyph-pixels (org-table-widget--measure-string glyph window)))
    (concat (propertize glyph 'face 'org-table-widget-border)
            (org-table-widget--pixel-space (max 0 (- pixels glyph-pixels))))))

(defun org-table-widget--boundary-pixels (window)
  "Return one normalized boundary width for all border glyphs in WINDOW."
  (apply #'max
         (mapcar (lambda (glyph) (org-table-widget--measure-string glyph window))
                 (if org-table-widget-use-unicode-borders
                     '("│" "┌" "┬" "┐" "├" "┼" "┤" "└" "┴" "┘")
                   '("|" "+")))))

(defun org-table-widget--rule-segment (pixels window)
  "Return a horizontal rule occupying PIXELS in WINDOW."
  (let* ((glyph (if org-table-widget-use-unicode-borders "─" "-"))
         (glyph-pixels (max 1 (org-table-widget--measure-string glyph window)))
         (count (floor (/ (float pixels) glyph-pixels)))
         (remainder (- pixels (* count glyph-pixels))))
    (propertize (concat (make-string count (string-to-char glyph))
                        (org-table-widget--pixel-space remainder))
                'face 'org-table-widget-border)))

(defun org-table-widget--rule (widths left join right boundary-pixels window)
  "Build a rule for WIDTHS in WINDOW.
LEFT, JOIN and RIGHT are normalized to BOUNDARY-PIXELS."
  (concat
   (org-table-widget--boundary left boundary-pixels window)
   (mapconcat (lambda (width) (org-table-widget--rule-segment width window))
              widths
              (org-table-widget--boundary join boundary-pixels window))
   (org-table-widget--boundary right boundary-pixels window)))

(defun org-table-widget--padding-widths (padding alignment)
  "Split PADDING pixels into left and right widths for ALIGNMENT."
  (pcase alignment
    ('right (cons padding 0))
    ('center (let ((left (/ padding 2)))
               (cons left (- padding left))))
    (_ (cons 0 padding))))

(defun org-table-widget--pad (text pixels window alignment)
  "Pad TEXT to PIXELS in WINDOW according to ALIGNMENT."
  (let* ((used (org-table-widget--measure-string text window))
         (padding (max 0 (- pixels used)))
         (widths (org-table-widget--padding-widths padding alignment)))
    (concat (org-table-widget--pixel-space (car widths))
            text
            (org-table-widget--pixel-space (cdr widths)))))

(defun org-table-widget--row (cells widths alignments row-face boundary-pixels
                                    window)
  "Render CELLS at pixel WIDTHS with ALIGNMENTS and ROW-FACE in WINDOW.
BOUNDARY-PIXELS is the uniform advance of every vertical border."
  (let* ((border (if org-table-widget-use-unicode-borders "│" "|"))
         (styled-border (org-table-widget--boundary border boundary-pixels
                                                    window))
         (space-pixels (org-table-widget--char-pixel-width window))
         (content-widths (mapcar (lambda (width)
                                   (max 1 (- width (* 2 space-pixels))))
                                 widths))
         (wrapped (seq-mapn (lambda (cell width)
                              (org-table-widget--wrap-pixels cell width window))
                            cells content-widths))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         lines)
    (dotimes (line-index height)
      (let (parts)
        (seq-mapn
         (lambda (cell-lines content-width alignment)
           (let* ((line (or (nth line-index cell-lines) ""))
                  (content (org-table-widget--pad line content-width window
                                                  alignment))
                  (cell (concat " " content " ")))
             (when row-face
               (add-face-text-property 0 (length cell) row-face t cell))
             (push cell parts)))
         wrapped content-widths alignments)
        (push (concat styled-border
                      (string-join (nreverse parts) styled-border)
                      styled-border)
              lines)))
    (string-join (nreverse lines) "\n")))

(defun org-table-widget--render (table window width)
  "Lay TABLE out for WINDOW at WIDTH columns and return the string.
TABLE is a plist with :rows (cell lists or `hline'), :alignments and
:header-rows, the number of leading rows before the first `hline'."
  (let* ((rows (plist-get table :rows))
         (alignments (plist-get table :alignments))
         (header-rows (plist-get table :header-rows))
         (columns (length alignments))
         (pixel-budget (org-table-widget--pixel-budget width window))
         (boundary-pixels (org-table-widget--boundary-pixels window))
         (widths (org-table-widget--widths rows columns pixel-budget
                                           boundary-pixels window))
         (unicode org-table-widget-use-unicode-borders)
         (top (if unicode '("┌" "┬" "┐") '("+" "+" "+")))
         (middle (if unicode '("├" "┼" "┤") '("|" "|" "|")))
         (bottom (if unicode '("└" "┴" "┘") '("+" "+" "+")))
         (row-index 0)
         (data-row-index 0)
         (parts (list (apply #'org-table-widget--rule
                             (append (list widths) top
                                     (list boundary-pixels window))))))
    (dolist (row rows)
      (if (eq row 'hline)
          (push (apply #'org-table-widget--rule
                       (append (list widths) middle
                               (list boundary-pixels window)))
                parts)
        (let* ((header (< row-index header-rows))
               (row-face (cond (header 'org-table-widget-header)
                               ((and org-table-widget-zebra-stripe
                                     (= (mod data-row-index 2) 1))
                                'org-table-widget-zebra))))
          (push (org-table-widget--row row widths alignments row-face
                                       boundary-pixels window)
                parts)
          (unless header
            (setq data-row-index (1+ data-row-index)))
          (setq row-index (1+ row-index)))))
    (push (apply #'org-table-widget--rule
                 (append (list widths) bottom (list boundary-pixels window)))
          parts)
    (let ((rendered (string-join (nreverse parts) "\n")))
      (add-face-text-property 0 (length rendered) 'fixed-pitch nil rendered)
      rendered)))

;;;; TextUI widget

(defun org-table-widget--layout (widget width)
  "Lay out table WIDGET within WIDTH columns for TextUI."
  (let ((table (widget-get widget :value))
        (window (or (widget-get widget :window)
                    (get-buffer-window (current-buffer))
                    (selected-window))))
    (org-table-widget--with-cached-measurements window
      (org-table-widget--render table window width))))

(define-widget 'org-table-widget 'default
  "A width-aware Org table."
  :format "%v"
  :textui-layout #'org-table-widget--layout)

;;;; Parsing Org tables

(defconst org-table-widget--cookie-regexp "\\`<\\([lrc]\\)?\\([0-9]+\\)?>\\'"
  "Regexp matching an Org alignment or width cookie.")

(defun org-table-widget--cookie-alignment (cell)
  "Return the alignment declared by cookie CELL, or nil."
  (when (string-match org-table-widget--cookie-regexp cell)
    (pcase (match-string 1 cell)
      ("r" 'right)
      ("c" 'center)
      ("l" 'left)
      (_ nil))))

(defun org-table-widget--cookie-row-p (cells)
  "Return non-nil when CELLS form a cookie-only row."
  (and (seq-some (lambda (cell) (string-match-p org-table-widget--cookie-regexp
                                                cell))
                 cells)
       (seq-every-p (lambda (cell)
                      (or (string-empty-p cell)
                          (string-match-p org-table-widget--cookie-regexp cell)))
                    cells)))

(defun org-table-widget--clean-cell (text)
  "Return TEXT trimmed, keeping only `org-table-widget-cell-properties'."
  (let ((cell (string-trim text)))
    (let ((position 0)
          (length (length cell)))
      (while (< position length)
        (let* ((next (or (next-property-change position cell) length))
               (plist (text-properties-at position cell))
               (drop (cl-loop for (key _value) on plist by #'cddr
                              unless (memq key org-table-widget-cell-properties)
                              collect key)))
          (when drop
            (remove-list-of-text-properties position next drop cell))
          (setq position next))))
    cell))

(defun org-table-widget--line-cells ()
  "Return the propertized cells of the table row on the current line."
  (let ((end (line-end-position))
        cells)
    (save-excursion
      (beginning-of-line)
      (skip-chars-forward " \t")
      (when (eq (char-after) ?|)
        (forward-char)
        (let ((start (point)))
          (while (re-search-forward "|" end 'move)
            (push (org-table-widget--clean-cell
                   (buffer-substring start (1- (point))))
                  cells)
            (setq start (point)))
          (when (< start end)
            (let ((tail (buffer-substring start end)))
              (unless (string-blank-p tail)
                (push (org-table-widget--clean-cell tail) cells)))))))
    (nreverse cells)))

(defun org-table-widget--parse (beg end)
  "Parse the Org table between BEG and END.
Return a plist with :rows, :alignments and :header-rows, or nil when
the region holds no data rows."
  (let (rows alignments cookie-row)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (cond
         ((looking-at-p org-table-hline-regexp)
          (push 'hline rows))
         ((looking-at-p org-table-dataline-regexp)
          (let ((cells (org-table-widget--line-cells)))
            (if (org-table-widget--cookie-row-p cells)
                (setq cookie-row cells)
              (push cells rows)))))
        (forward-line 1)))
    (setq rows (nreverse rows))
    ;; Drop leading and trailing rules and merge adjacent ones.
    (while (eq (car rows) 'hline) (setq rows (cdr rows)))
    (setq rows (nreverse rows))
    (while (eq (car rows) 'hline) (setq rows (cdr rows)))
    (setq rows (nreverse rows))
    (let (merged previous)
      (dolist (row rows)
        (unless (and (eq row 'hline) (eq previous 'hline))
          (push row merged))
        (setq previous row))
      (setq rows (nreverse merged)))
    (when rows
      (let* ((columns (apply #'max (mapcar (lambda (row)
                                             (if (eq row 'hline) 0 (length row)))
                                           rows)))
             (header-rows (or (cl-position 'hline rows) 0)))
        (setq rows (mapcar (lambda (row)
                             (if (eq row 'hline)
                                 row
                               (append row (make-list (- columns (length row))
                                                      ""))))
                           rows))
        (setq alignments
              (cl-loop for column below columns
                       collect (or (and cookie-row
                                        (org-table-widget--cookie-alignment
                                         (or (nth column cookie-row) "")))
                                   'left)))
        (list :rows rows :alignments alignments :header-rows header-rows)))))

;;;; Overlays

(defvar-local org-table-widget--overlays nil
  "Overlays displaying table widgets in the current buffer.")

(defvar-local org-table-widget--width nil
  "Window width in columns the widgets were last laid out for.")

(defvar-local org-table-widget--timer nil
  "Idle timer for a pending relayout.")

(defvar-local org-table-widget--inside-table nil
  "Non-nil while point is inside a revealed table.")

(defun org-table-widget--window ()
  "Return the window to lay tables out for, or nil."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (or (and (memq (selected-window) windows) (selected-window))
        (car windows))))

(defun org-table-widget--layout-width (window)
  "Return the column width available for widgets in WINDOW."
  (if (window-live-p window)
      (apply #'min (mapcar #'window-body-width
                           (get-buffer-window-list (current-buffer) nil t)))
    80))

(defun org-table-widget--tables ()
  "Return (BEG . END) for every Org table in the accessible buffer."
  (let (tables)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-table-any-line-regexp nil t)
        (if (org-at-table.el-p)
            (goto-char (org-table-end))
          (if (org-at-table-p)
              (let ((beg (org-table-begin))
                    (end (org-table-end)))
                (push (cons beg end) tables)
                (goto-char end))
            (forward-line 1)))))
    (nreverse tables)))

(defun org-table-widget--overlay-at (position)
  "Return the widget overlay covering POSITION, or nil."
  (seq-find (lambda (overlay) (overlay-get overlay 'org-table-widget))
            (overlays-in position (1+ position))))

(defun org-table-widget--remove-overlay (overlay)
  "Delete widget OVERLAY and forget it."
  (delete-overlay overlay)
  (setq org-table-widget--overlays (delq overlay org-table-widget--overlays)))

(defun org-table-widget--modified (overlay &rest _)
  "Reveal the source when the table under OVERLAY is modified."
  (when (overlay-buffer overlay)
    (with-current-buffer (overlay-buffer overlay)
      (org-table-widget--remove-overlay overlay)
      (org-table-widget--schedule-relayout))))

(defun org-table-widget--display-table (beg end window width)
  "Cover the table between BEG and END with a widget for WINDOW at WIDTH."
  (font-lock-ensure beg end)
  (when-let* ((table (org-table-widget--parse beg end)))
    (let* ((widget (widget-convert 'org-table-widget :value table
                                   :window window))
           (rendered (textui-layout-widget widget width))
           (overlay (make-overlay beg end nil t nil)))
      (overlay-put overlay 'org-table-widget widget)
      ;; Replacement strings ignore nested `display' properties, including
      ;; our pixel spaces.  A before-string honors them while the empty
      ;; replacement hides the source, still using one overlay per table.
      (overlay-put overlay 'display "")
      (overlay-put overlay 'before-string
                   (if (eq (char-before end) ?\n)
                       (concat rendered "\n")
                     rendered))
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'modification-hooks
                   (list #'org-table-widget--modified))
      (overlay-put overlay 'insert-in-front-hooks
                   (list #'org-table-widget--modified))
      (push overlay org-table-widget--overlays)
      overlay)))

(defun org-table-widget--clear ()
  "Remove every widget overlay from the current buffer."
  (mapc #'delete-overlay org-table-widget--overlays)
  (setq org-table-widget--overlays nil))

(defun org-table-widget-refresh ()
  "Lay out every table in the current buffer as a widget.
A table containing point is left as source when
`org-table-widget-reveal-on-point' is non-nil."
  (interactive)
  (org-table-widget--cancel-relayout)
  (org-table-widget--clear)
  (let ((window (org-table-widget--window)))
    (when (and (window-live-p window) (display-graphic-p (window-frame window)))
      (let ((width (org-table-widget--layout-width window))
            (point (point)))
        (save-excursion
          (dolist (table (org-table-widget--tables))
            (unless (and org-table-widget-reveal-on-point
                         (>= point (car table))
                         (< point (cdr table)))
              (org-table-widget--display-table (car table) (cdr table)
                                               window width))))
        (setq org-table-widget--width width)))))

(defun org-table-widget--display-missing ()
  "Display widgets for tables that have none, except the one at point."
  (let ((window (org-table-widget--window)))
    (when (and (window-live-p window) (display-graphic-p (window-frame window)))
      (let ((width (or org-table-widget--width
                       (org-table-widget--layout-width window)))
            (point (point)))
        (save-excursion
          (dolist (table (org-table-widget--tables))
            (unless (or (org-table-widget--overlay-at (car table))
                        (and org-table-widget-reveal-on-point
                             (>= point (car table))
                             (< point (cdr table))))
              (org-table-widget--display-table (car table) (cdr table)
                                               window width))))))))

(defun org-table-widget--cancel-relayout ()
  "Cancel a pending relayout."
  (when org-table-widget--timer
    (cancel-timer org-table-widget--timer)
    (setq org-table-widget--timer nil)))

(defun org-table-widget--run-relayout (buffer)
  "Relayout BUFFER's widgets when its window width changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq org-table-widget--timer nil)
      (when org-table-widget-mode
        (org-table-widget-refresh)))))

(defun org-table-widget--schedule-relayout ()
  "Relayout after the window configuration settles."
  (when org-table-widget-mode
    (org-table-widget--cancel-relayout)
    (if (<= org-table-widget-relayout-delay 0)
        (org-table-widget--run-relayout (current-buffer))
      (setq org-table-widget--timer
            (run-with-idle-timer org-table-widget-relayout-delay nil
                                 #'org-table-widget--run-relayout
                                 (current-buffer))))))

(defun org-table-widget--window-changed ()
  "Schedule a relayout when the window width changed."
  (let ((window (org-table-widget--window)))
    (when (and (window-live-p window)
               (not (equal (org-table-widget--layout-width window)
                           org-table-widget--width)))
      (org-table-widget--schedule-relayout))))

(defun org-table-widget--post-command ()
  "Reveal the table under point and restore widgets point has left."
  (when org-table-widget-reveal-on-point
    (let ((overlay (org-table-widget--overlay-at (point))))
      (cond
       (overlay
        (org-table-widget--remove-overlay overlay)
        (setq org-table-widget--inside-table t))
       ((and org-table-widget--inside-table
             (not (org-at-table-p)))
        (setq org-table-widget--inside-table nil)
        (org-table-widget--display-missing))
       ((org-at-table-p)
        (setq org-table-widget--inside-table t))))))

(defun org-table-widget-toggle ()
  "Toggle the widget for the table at point."
  (interactive)
  (let ((overlay (org-table-widget--overlay-at (point))))
    (cond
     (overlay
      (org-table-widget--remove-overlay overlay)
      (setq org-table-widget--inside-table t))
     ((org-at-table-p)
      (let ((window (org-table-widget--window)))
        (when (window-live-p window)
          (let ((org-table-widget-reveal-on-point nil)
                (beg (org-table-begin))
                (end (org-table-end)))
            (org-table-widget--display-table
             beg end window (org-table-widget--layout-width window))
            (goto-char end)
            (setq org-table-widget--inside-table nil)))))
     (t (user-error "Not at an Org table")))))

;;;###autoload
(define-minor-mode org-table-widget-mode
  "Show Org tables as responsive pixel-aligned widgets.
The buffer text is left untouched; each table is covered by an overlay
displaying its widget.  Moving point into a table reveals its source."
  :lighter " OTW"
  (if org-table-widget-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (setq org-table-widget-mode nil)
          (user-error "Org table widgets require Org mode"))
        (unless (require 'textui nil t)
          (setq org-table-widget-mode nil)
          (user-error "Org table widgets require TextUI"))
        (add-hook 'post-command-hook #'org-table-widget--post-command nil t)
        (add-hook 'window-configuration-change-hook
                  #'org-table-widget--window-changed nil t)
        (add-hook 'text-scale-mode-hook #'org-table-widget--schedule-relayout
                  nil t)
        (org-table-widget-refresh))
    (remove-hook 'post-command-hook #'org-table-widget--post-command t)
    (remove-hook 'window-configuration-change-hook
                 #'org-table-widget--window-changed t)
    (remove-hook 'text-scale-mode-hook #'org-table-widget--schedule-relayout t)
    (org-table-widget--cancel-relayout)
    (org-table-widget--clear)))

(provide 'org-table-widget)
;;; org-table-widget.el ends here
