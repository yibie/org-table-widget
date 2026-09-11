;;; visual-check.el --- Capture and measure scenario displays -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run from any directory:
;; /opt/homebrew/bin/Emacs -Q -l /Users/chenyibin/Documents/emacs/package/org-table-widget/demos/visual-check.el
;; GUI Emacs.app does NOT inherit the shell cwd.  Use absolute -l, --eval
;; file names, and log paths, or pass --chdir with the repository first.
;; Prefer --batch for checks that do not need real pixels.
;; Screenshots are captured but not inspected.  Logical line widths and border
;; advances are measured as overlay before-strings in a GUI measurement buffer
;; at the same window width/font.  This also covers off-screen rows of large.org.
;;; Code:
(require 'cl-lib)
(require 'seq)

(defconst org-table-widget-visual--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing visual fixtures and logs.")
(add-to-list 'load-path (expand-file-name ".." org-table-widget-visual--directory))
(add-to-list 'load-path (expand-file-name "../../textui" org-table-widget-visual--directory))
(require 'org-table-widget)

(defun org-table-widget-visual--log (format-string &rest args)
  "Append FORMAT-STRING formatted with ARGS to visual.log."
  (write-region (concat (apply #'format format-string args) "\n") nil
                (expand-file-name "visual.log" org-table-widget-visual--directory)
                t 'silent))

(defun org-table-widget-visual--width (string overlay)
  "Measure STRING as a GUI before-string on measurement OVERLAY."
  (overlay-put overlay 'before-string string)
  (car (window-text-pixel-size nil (point-min) (point-max) 100000)))

(defun org-table-widget-visual--table (rendered metadata)
  "Check RENDERED lines and borders, reporting source METADATA."
  (let* ((lines (split-string (string-trim-right rendered "\n") "\n"))
         (body-width (window-body-width nil t))
         (header (plist-get metadata :header-rows))
         (first-rule (cl-position-if (lambda (line) (string-prefix-p "├" line)) lines))
         (selected (list (cons 'top 0)
                         (cons 'header (and (> header 0) 1))
                         (cons 'first-data (if (> header 0) (1+ first-rule) 1))
                         (cons 'last-data (- (length lines) 2))
                         (cons 'bottom (1- (length lines)))))
         widths borders overflow)
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (setq-local truncate-lines t)
        (insert "x")
        (let ((overlay (make-overlay (point-min) (point-max))))
          (overlay-put overlay 'display "")
          (cl-loop for line in lines for index from 0
                   for width = (org-table-widget-visual--width line overlay)
                   do (push width widths)
                   when (> width body-width)
                   do (push (cons (1+ index) width) overflow))
          (dolist (entry selected)
            (when (cdr entry)
              (let* ((line (nth (cdr entry) lines))
                     (index (cl-position-if
                             (lambda (char) (memq char '(?│ ?┐ ?┘)))
                             line :from-end t))
                     (x (and index (org-table-widget-visual--width
                                    (substring line 0 index) overlay))))
                (push (cons (car entry) x) borders)))))))
    (setq widths (nreverse widths) borders (nreverse borders))
    (org-table-widget-visual--log "TABLE %S body=%dpx lines=%d borders=%S max-width=%d"
                                  metadata body-width (length lines) borders
                                  (apply #'max widths))
    (org-table-widget-visual--log "LINE-WIDTHS %S" widths)
    (condition-case err
        (cl-assert (and (cl-every #'numberp (mapcar #'cdr borders))
                        (apply #'= (mapcar #'cdr borders))))
      (error (org-table-widget-visual--log "FAIL BORDER %S %S" metadata err)))
    (condition-case err
        (cl-assert (null overflow))
      (error (org-table-widget-visual--log "FAIL WIDTH %S overflow=%S %S"
                                           metadata (reverse overflow) err)))))

(defun org-table-widget-visual--fold-check ()
  "Check that folding a heading hides its table widget in actual redisplay."
  (goto-char (point-min))
  (re-search-forward "^\\* Initially folded heading")
  (beginning-of-line)
  (let* ((heading (point))
         (beg (save-excursion (re-search-forward "^| Hidden") (line-beginning-position)))
         (overlay (org-table-widget--overlay-at beg))
         (rendered (overlay-get overlay 'before-string))
         seen)
    (org-fold-hide-subtree)
    (goto-char (point-min))
    (set-window-start nil (point-min))
    (redisplay t)
    (cl-loop for y from 0 below (window-body-height nil t) by 4
             until seen
             do (cl-loop for x from 0 below (window-body-width nil t) by 4
                         for pos = (posn-at-x-y x y)
                         for string = (and pos (posn-string pos))
                         when (and string (eq (car string) rendered))
                         do (setq seen (posn-x-y pos))
                         and return t))
    (org-table-widget-visual--log "FOLD heading=%d table=%d source-invisible=%S widget-visible=%S"
                                  heading beg (invisible-p beg) seen)
    (when seen
      (org-table-widget-visual--log "FAIL FOLD adjacent-and-nested.org table=4 xy=%S" seen))
    (call-process "/usr/sbin/screencapture" nil nil nil "-x"
                  (expand-file-name "shots/adjacent-and-nested-folded.png"
                                    org-table-widget-visual--directory))))

(defun org-table-widget-visual--markup-check ()
  "Log faces and verify hidden link brackets retain their display behavior."
  (let* ((overlay (car org-table-widget--overlays))
         (table (widget-get (overlay-get overlay 'org-table-widget) :value))
         (rows (plist-get table :rows))
         (links (seq-find (lambda (row) (and (listp row) (equal (car row) "links"))) rows))
         (cell (nth 1 links)))
    (org-table-widget-visual--log "MARKUP link-cell=%S" cell)
    (let ((start (string-match "short description" cell)))
      (save-window-excursion
        (with-temp-buffer
          (switch-to-buffer (current-buffer))
          (insert "x")
          (let ((probe (make-overlay 1 2)))
            (overlay-put probe 'display "")
            (let ((whole (org-table-widget-visual--width cell probe))
                  (description (org-table-widget-visual--width
                                (substring cell start (+ start (length "short description"))) probe)))
              (org-table-widget-visual--log "LINK whole=%dpx description=%dpx brackets-hidden=%S"
                                            whole description (= whole description))
              (unless (= whole description)
                (org-table-widget-visual--log "FAIL LINK inline-markup.org table=1")))))))
    (dolist (label '("emphasis" "literals" "footnote" "timestamp" "math" "entity"))
      (let ((row (seq-find (lambda (row) (and (listp row) (equal (car row) label))) rows)))
        (org-table-widget-visual--log "MARKUP %s=%S" label (nth 1 row))))))

(defun org-table-widget-visual--file (name width)
  "Capture and check demo NAME at frame WIDTH pixels."
  (set-frame-size nil width 800 t)
  (let ((buffer (find-file-noselect
                 (expand-file-name name org-table-widget-visual--directory))))
    (unwind-protect
        (with-current-buffer buffer
          (switch-to-buffer buffer)
          (goto-char (point-min))
          (setq-local org-table-widget-relayout-delay 3600)
          (org-table-widget-mode 1)
          (select-frame-set-input-focus (selected-frame))
          (redisplay t)
          (sleep-for 0.15)
          (let* ((shot (expand-file-name
                        (format "shots/%s-%d.png" (file-name-base name) width)
                        org-table-widget-visual--directory))
                 (status (call-process "/usr/sbin/screencapture" nil nil nil "-x" shot)))
            (org-table-widget-visual--log "SCREENSHOT %s status=%S exists=%S"
                                          shot status (file-exists-p shot)))
          (let ((index 0))
            (dolist (overlay (sort (copy-sequence org-table-widget--overlays)
                                   (lambda (a b) (< (overlay-start a) (overlay-start b)))))
              (cl-incf index)
              (org-table-widget-visual--table
               (overlay-get overlay 'before-string)
               (list :file name :frame width :columns (window-body-width) :table index
                     :line (line-number-at-pos (overlay-start overlay))
                     :hidden (invisible-p (overlay-start overlay))
                     :header-rows (plist-get
                                   (widget-get (overlay-get overlay 'org-table-widget) :value)
                                   :header-rows)))))
          (when (equal name "inline-markup.org")
            (org-table-widget-visual--markup-check))
          ;; Inspect the nested fixture after unfolding as well as its initial state.
          (when (equal name "adjacent-and-nested.org")
            (org-table-widget-visual--fold-check)
            (org-fold-show-all)
            (org-table-widget-refresh)
            (redisplay t)
            (let ((status (call-process
                           "/usr/sbin/screencapture" nil nil nil "-x"
                           (expand-file-name "shots/adjacent-and-nested-unfolded.png"
                                             org-table-widget-visual--directory))))
              (org-table-widget-visual--log "UNFOLDED screenshot=%S overlays=%d"
                                            status (length org-table-widget--overlays)))))
      (with-current-buffer buffer (org-table-widget-mode -1))
      (kill-buffer buffer))))

(defun org-table-widget-visual--height (overlay truncate)
  "Return the pixel height of widget OVERLAY with `truncate-lines' TRUNCATE."
  (let ((truncate-lines truncate))
    (cdr (window-text-pixel-size nil (overlay-start overlay)
                                 (overlay-end overlay)))))

(defun org-table-widget-visual--wrapped-tables ()
  "Return the indexes of widgets whose lines wrap in the selected window.
A widget that fits keeps its height when lines may not wrap.  The display
iterator draws line numbers and keeps the continuation column exactly as
redisplay does; starting at the table, it sizes the number area for the
table's own line, which makes this check pessimistic."
  (cl-loop for overlay in (sort (copy-sequence org-table-widget--overlays)
                                (lambda (a b)
                                  (< (overlay-start a) (overlay-start b))))
           for index from 1
           unless (= (org-table-widget-visual--height overlay nil)
                     (org-table-widget-visual--height overlay t))
           collect index))

(defun org-table-widget-visual--gutter-check (name width)
  "Check that widgets in demo NAME fit beside line numbers and without fringes.
Lay the tables out in a frame WIDTH pixels wide for every combination."
  (set-frame-size nil width 800 t)
  (let ((buffer (find-file-noselect
                 (expand-file-name name org-table-widget-visual--directory))))
    (unwind-protect
        (with-current-buffer buffer
          (switch-to-buffer buffer)
          (goto-char (point-min))
          (setq-local org-table-widget-relayout-delay 3600)
          (org-table-widget-mode 1)
          (pcase-dolist (`(,fringe ,numbers) '((8 nil) (0 nil) (8 t) (0 t)))
            (set-window-fringes nil fringe fringe)
            (display-line-numbers-mode (if numbers 1 -1))
            (org-table-widget-refresh)
            (redisplay t)
            (let ((wrapped (org-table-widget-visual--wrapped-tables)))
              (org-table-widget-visual--log
               "GUTTER %s frame=%d fringes=%d numbers=%S width=%S wrapped=%S"
               name width fringe numbers
               (and numbers (line-number-display-width t)) wrapped)
              (when wrapped
                (org-table-widget-visual--log
                 "FAIL GUTTER %s frame=%d fringes=%d numbers=%S tables=%S"
                 name width fringe numbers wrapped)))))
      (with-current-buffer buffer
        (display-line-numbers-mode -1)
        (set-window-fringes nil nil nil)
        (org-table-widget-mode -1))
      (kill-buffer buffer))))

(defun org-table-widget-visual-main ()
  "Capture all non-huge demos and check pixel geometry in GUI Emacs."
  (condition-case err
      (progn
        (set-face-attribute 'default nil :family "Iosevka" :height 150)
        (set-face-attribute 'fixed-pitch nil :family "Iosevka" :height 150)
        (make-directory (expand-file-name "shots" org-table-widget-visual--directory) t)
        (write-region "" nil (expand-file-name "visual.log" org-table-widget-visual--directory))
        (org-table-widget-visual--log "Emacs=%s font=%S graphic=%S" emacs-version
                                      (face-font 'default) (display-graphic-p))
        (dolist (file (directory-files org-table-widget-visual--directory nil "\\.org\\'"))
          (unless (equal file "huge.org")
            (org-table-widget-visual--file file 1400)))
        (dolist (file '("mixed-scripts.org" "narrow-window.org"))
          (org-table-widget-visual--file file 700))
        ;; Additional requested character-width scenarios; still no image inspection.
        (dolist (columns '(60 80 120))
          (org-table-widget-visual--file "narrow-window.org"
                                         (* columns (frame-char-width))))
        ;; Full-width tables beside line numbers and without fringes; the
        ;; last table of line-numbers.org sits where numbers need three digits.
        (org-table-widget-visual--gutter-check "narrow-window.org" 700)
        (org-table-widget-visual--gutter-check "line-numbers.org" 1000)
        (org-table-widget-visual--log "COMPLETE"))
    (error (org-table-widget-visual--log "ERROR %S" err)))
  (kill-emacs))

(unless noninteractive
  (run-with-timer 1 nil #'org-table-widget-visual-main))

(provide 'org-table-widget-demo-visual)
;;; visual-check.el ends here
