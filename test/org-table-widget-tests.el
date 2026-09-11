;;; org-table-widget-tests.el --- Tests for org-table-widget  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L <textui> -l org-table-widget.el \
;;     -l test/org-table-widget-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-table-widget)

(defun org-table-widget-tests--pixels (string)
  "Return a deterministic pixel width for STRING: 10 per display column."
  (* 10 (string-width (substring-no-properties string))))

(defmacro org-table-widget-tests--with-pixel-mocks (&rest body)
  "Run BODY with deterministic pixel measurement."
  `(cl-letf (((symbol-function 'org-table-widget--measure-string)
              (lambda (string _window)
                (org-table-widget-tests--pixels string)))
             ((symbol-function 'org-table-widget--char-pixel-width)
              (lambda (_window) 10))
             ((symbol-function 'org-table-widget--pixel-budget)
              (lambda (width _window) (* 10 width))))
     ,@body))

(defmacro org-table-widget-tests--with-org (text &rest body)
  "Run BODY in an Org buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(defun org-table-widget-tests--lines (string)
  "Split rendered STRING into lines without properties."
  (split-string (substring-no-properties string) "\n"))

;;;; Parsing

(ert-deftest org-table-widget-parse-header-and-groups ()
  (org-table-widget-tests--with-org "| A | B |\n|---+---|\n| 1 | 2 |\n|---+---|\n| 3 | 4 |\n"
    (let ((table (org-table-widget--parse (point-min) (point-max))))
      (should (equal (plist-get table :header-rows) 1))
      (should (equal (plist-get table :alignments) '(left left)))
      (should (equal (mapcar (lambda (row)
                               (if (eq row 'hline)
                                   row
                                 (mapcar #'substring-no-properties row)))
                             (plist-get table :rows))
                     '(("A" "B") hline ("1" "2") hline ("3" "4")))))))

(ert-deftest org-table-widget-parse-without-hline-has-no-header ()
  (org-table-widget-tests--with-org "| a | b |\n| c | d |\n"
    (let ((table (org-table-widget--parse (point-min) (point-max))))
      (should (equal (plist-get table :header-rows) 0))
      (should (equal (length (plist-get table :rows)) 2)))))

(ert-deftest org-table-widget-parse-drops-outer-and-duplicate-rules ()
  (org-table-widget-tests--with-org "|---|\n| a |\n|---|\n|---|\n| b |\n|---|\n"
    (let ((rows (plist-get (org-table-widget--parse (point-min) (point-max))
                           :rows)))
      (should (equal (length rows) 3))
      (should (eq (nth 1 rows) 'hline)))))

(ert-deftest org-table-widget-parse-alignment-cookies ()
  (org-table-widget-tests--with-org "| Item | Qty | Price |\n| <l> | <r> | <c10> |\n|---+---+---|\n| x | 1 | 2 |\n"
    (let ((table (org-table-widget--parse (point-min) (point-max))))
      (should (equal (plist-get table :alignments) '(left right center)))
      ;; The cookie row is not displayed.
      (should (equal (length (plist-get table :rows)) 3))
      (should (equal (plist-get table :header-rows) 1)))))

(ert-deftest org-table-widget-parse-pads-short-rows ()
  (org-table-widget-tests--with-org "| a | b | c |\n| d |\n"
    (let ((rows (plist-get (org-table-widget--parse (point-min) (point-max))
                           :rows)))
      (should (equal (length (nth 1 rows)) 3))
      (should (equal (substring-no-properties (nth 2 (nth 1 rows))) "")))))

(ert-deftest org-table-widget-parse-row-without-trailing-pipe ()
  (org-table-widget-tests--with-org "| a | b\n"
    (let ((rows (plist-get (org-table-widget--parse (point-min) (point-max))
                           :rows)))
      (should (equal (mapcar #'substring-no-properties (car rows))
                     '("a" "b"))))))

(ert-deftest org-table-widget-cells-keep-faces-and-drop-other-properties ()
  (org-table-widget-tests--with-org "| *bold* | plain |\n"
    (font-lock-ensure)
    (put-text-property 3 7 'fontified t)
    (put-text-property 3 7 'line-prefix "  ")
    (let* ((cell (car (car (plist-get (org-table-widget--parse (point-min)
                                                                (point-max))
                                      :rows))))
           (faces (get-text-property 1 'face cell)))
      (should (string-equal (substring-no-properties cell) "*bold*"))
      (should (or (eq faces 'bold) (memq 'bold (ensure-list faces))
                  (eq faces 'org-bold)))
      (should-not (get-text-property 1 'line-prefix cell))
      (should-not (get-text-property 1 'fontified cell)))))

(ert-deftest org-table-widget-parse-empty-table-returns-nil ()
  (org-table-widget-tests--with-org "|---|\n"
    (should-not (org-table-widget--parse (point-min) (point-max)))))

;;;; Layout

(ert-deftest org-table-widget-render-shape ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((table (list :rows '(("A" "B") hline ("1" "22") hline ("x" "y"))
                       :alignments '(left left)
                       :header-rows 1))
          (lines (org-table-widget-tests--lines
                  (org-table-widget--render table nil 80))))
     ;; top, header, rule, row, rule, row, bottom
     (should (equal (length lines) 7))
     (should (string-prefix-p "┌" (nth 0 lines)))
     (should (string-prefix-p "├" (nth 2 lines)))
     (should (string-prefix-p "├" (nth 4 lines)))
     (should (string-prefix-p "└" (nth 6 lines))))))

(ert-deftest org-table-widget-render-header-face ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((table (list :rows '(("Head") hline ("data"))
                       :alignments '(left) :header-rows 1))
          (rendered (org-table-widget--render table nil 80))
          (head (string-match "Head" rendered))
          (data (string-match "data" rendered)))
     (should (memq 'org-table-widget-header
                   (ensure-list (get-text-property head 'face rendered))))
     (should-not (memq 'org-table-widget-header
                       (ensure-list (get-text-property data 'face rendered)))))))

(ert-deftest org-table-widget-render-wraps-long-cells ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((long (mapconcat #'identity (make-list 12 "word") " "))
          (table (list :rows `(("k" ,long)) :alignments '(left left)
                       :header-rows 0))
          (lines (org-table-widget-tests--lines
                  (org-table-widget--render table nil 30))))
     ;; A 59-column cell in a 30-column window needs several lines.
     (should (> (length lines) 3))
     (dolist (line lines)
       (should (<= (string-width line) 30))))))

(ert-deftest org-table-widget-longest-token-pixels ()
  (org-table-widget-tests--with-pixel-mocks
   (should (= (org-table-widget--longest-token-pixels "ab cdef g" nil) 40))
   (should (= (org-table-widget--longest-token-pixels "用户面只留" nil) 20))
   (should (= (org-table-widget--longest-token-pixels "" nil) 0))))

(ert-deftest org-table-widget-short-columns-keep-natural-width ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((giant (mapconcat #'identity (make-list 100 "lorem") " "))
          (rows `(("id" "status" ,giant)))
          (widths (org-table-widget--widths rows 3 1000 10 nil)))
     ;; "id" and "status" fit their natural width exactly, since their
     ;; growth above the minimum is well within the flexible space; the
     ;; giant column takes what is left over.
     (should (equal widths '(40 80 840))))))

(defconst org-table-widget-tests--issue-2-rows
  '(("sequence" "100 m" "200 m" "400 m" "G path" "spins" "portals")
    hline
    ("kartom-04" "0.6296 %" "0.3853 %" "0.4070 %" "773.8 m" "6828" "187")
    ("kartom-05" "0.8801 %" "0.5603 %" "0.2783 %" "695.1 m" "5834" "166")
    ("kartom-02" "0.6750 %" "0.5293 %"
     "this is some longer text that seems to cause trouble" "290.5 m"
     "3007" "69"))
  "Issue #2 table: short numeric cells beside a long text column.")

(ert-deftest org-table-widget-issue-2-short-numeric-columns-stay-whole ()
  (org-table-widget-tests--with-pixel-mocks
   (dolist (case '((800 . (110 100 100 160 90 70 90))
                   (1000 . (110 100 100 360 90 70 90))
                   (1100 . (110 100 100 460 90 70 90))))
     (should (equal (org-table-widget--widths
                     org-table-widget-tests--issue-2-rows 7 (car case) 10 nil)
                    (cdr case))))
   ;; Only 30 px exist above the minimums, too little to settle the
   ;; short columns at their natural width.
   (should (equal (org-table-widget--widths
                   org-table-widget-tests--issue-2-rows 7 700 10 nil)
                  '(110 82 82 113 73 70 90)))))

(ert-deftest org-table-widget-tight-budget-settles-cheapest-column-only ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((rows `(("ab cd" "abcd efgh" "abcd efgh"
                   ,(mapconcat #'identity (make-list 10 "word") " "))))
          (widths (org-table-widget--widths rows 4 410 10 nil)))
     (should (equal widths '(70 85 85 120))))))

(ert-deftest org-table-widget-two-long-columns-share-evenly ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((a20 (mapconcat #'identity (make-list 20 "alpha") " "))
          (rows `(("k" ,a20 ,a20)))
          (widths (org-table-widget--widths rows 3 500 10 nil)))
     (should (equal widths '(30 215 215))))))

(ert-deftest org-table-widget-rounding-spreads-the-remainder ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((cell (mapconcat #'identity (make-list 8 "ab") " "))
          (rows (list (list cell cell cell))))
     (let ((widths (org-table-widget--widths rows 3 270 10 nil)))
       (should (equal widths '(76 77 77)))
       (should (= (apply #'+ widths) 230)))
     (let ((widths (org-table-widget--widths rows 3 260 10 nil)))
       (should (equal widths '(73 73 74)))
       (should (= (apply #'+ widths) 220))))))

(ert-deftest org-table-widget-capped-token-does-not-overfeed-short-columns ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((rows '(("supertag-node-delete-everything" "ab cd" "ef gh")))
          (widths (org-table-widget--widths rows 3 400 10 nil)))
     ;; The old proportional split over-fed short columns beyond their
     ;; natural width: (201 79 80).  The capped weight must not do that.
     (should (equal widths '(220 70 70))))))

(ert-deftest org-table-widget-shares-recompute-after-every-grant ()
  (org-table-widget-tests--with-pixel-mocks
   (let ((widths (org-table-widget--widths
                  '(("ab cd ef g" "abcdefghijklmnop xyz")) 2 350 10 nil)))
     ;; Granting both columns against shares computed once per pass
     ;; would return (120 220) = 340, overflowing the 320 available.
     (should (equal widths '(100 220)))
     (should (= (apply #'+ widths) 320)))))

(ert-deftest org-table-widget-issue-2-render-keeps-numeric-cells-whole ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((table (list :rows org-table-widget-tests--issue-2-rows
                       :alignments (make-list 7 'left)
                       :header-rows 1))
          (lines (org-table-widget-tests--lines
                  (org-table-widget--render table nil 100)))
          (plain (mapconcat #'identity lines "\n")))
     (should (string-match-p (regexp-quote "0.6296 %") plain))
     (should (string-match-p (regexp-quote "773.8 m") plain))
     (should (> (length lines) 7)))))

(ert-deftest org-table-widget-minimum-keeps-unbreakable-token ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((rows '(("supertag-node-delete" "x")))
          (widths (org-table-widget--widths rows 2 400 10 nil)))
     ;; 20 chars = 200px + 20 padding; the token is never split.
     (should (= (nth 0 widths) 220)))))

(ert-deftest org-table-widget-right-alignment-pads-left ()
  (org-table-widget-tests--with-pixel-mocks
   (let* ((padded (org-table-widget--pad "7" 50 nil 'right)))
     (should (string-prefix-p "​" padded))
     (should (string-suffix-p "7" padded)))))

(ert-deftest org-table-widget-grapheme-clusters ()
  (should (equal (org-table-widget--grapheme-ends "🇯🇵a" 0) '(2 3)))
  (should (equal (org-table-widget--grapheme-ends "👨‍👩‍👧x" 0) '(5 6))))

;;;; Overlays

(ert-deftest org-table-widget-reveal-entry-direction ()
  ;; Simulate the landing position produced by display-based vertical motion.
  (dolist (case '((previous-line below last)
                  (next-line below last) ; Negative prefix argument.
                  (next-line above first)
                  (isearch-backward below first)))
    (org-table-widget-tests--with-org "Before\n| a |\n| b |\n| c |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-table-widget-mode 1)
        (unwind-protect
            (let* ((org-table-widget-reveal-on-point t)
                   (table (car (org-table-widget--tables)))
                   (overlay (org-table-widget--display-table
                             (car table) (cdr table) (selected-window) 80))
                   (this-command (car case)))
              (goto-char (if (eq (nth 1 case) 'below) (cdr table) (point-min)))
              (run-hooks 'pre-command-hook)
              (goto-char (car table))
              (run-hooks 'post-command-hook)
              (should (= (line-number-at-pos)
                         (if (eq (nth 2 case) 'last) 4 2)))
              (should-not (overlay-buffer overlay))
              (should org-table-widget--inside-table))
          (org-table-widget-mode -1))))))

(ert-deftest org-table-widget-reveal-skipped-table ()
  ;; A display-based Down can cross the entire overlay in one step.
  (dolist (command '(next-line previous-line isearch-forward))
    (org-table-widget-tests--with-org "Before\n| a |\n| b |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-table-widget-mode 1)
        (unwind-protect
            (let* ((org-table-widget-reveal-on-point t)
                   (table (car (org-table-widget--tables)))
                   (overlay (org-table-widget--display-table
                             (car table) (cdr table) (selected-window) 80))
                   (this-command command))
              (run-hooks 'pre-command-hook)
              (goto-char (cdr table))
              (run-hooks 'post-command-hook)
              (if (eq command 'isearch-forward)
                  (progn
                    (should (= (point) (cdr table)))
                    (should (overlay-buffer overlay)))
                (should (= (point) (car table)))
                (should-not (overlay-buffer overlay))
                (should org-table-widget--inside-table)))
          (org-table-widget-mode -1))))))

(ert-deftest org-table-widget-reveal-vertical-interactive ()
  ;; Redisplay is required: batch line motion ignores the preview's geometry.
  (skip-unless (not noninteractive))
  (dolist (visual '(nil t))
    (dolist (command '(next-line previous-line))
      (org-table-widget-tests--with-org "Before\n| a |\n| b |\n| c |\nAfter\n"
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (when visual (visual-line-mode 1))
          (goto-char (point-max))
          (org-table-widget-mode 1)
          (unwind-protect
              (let ((org-table-widget-reveal-on-point t)
                    (table (car (org-table-widget--tables))))
                (unless org-table-widget--overlays
                  (org-table-widget--display-table
                   (car table) (cdr table) (selected-window) 80))
                (goto-char (if (eq command 'next-line) (point-min) (cdr table)))
                (redisplay t)
                (let ((this-command command))
                  (run-hooks 'pre-command-hook)
                  (call-interactively command)
                  (run-hooks 'post-command-hook))
                (should (= (line-number-at-pos)
                           (if (eq command 'next-line) 2 4)))
                (should-not org-table-widget--overlays))
            (org-table-widget-mode -1)))))))

(ert-deftest org-table-widget-rest-steps-over-widget ()
  ;; (COMMAND FROM LANDING EXPECTED): where a command left point, and where
  ;; point settles.  The first case is where display-based Down lands.
  (dolist (case '((next-line before end start)
                  (next-line start end end)
                  (previous-line end start start)
                  (forward-char start inside end)
                  (backward-char end inside start)
                  (next-line before inside start)   ; Logical line motion.
                  (goto-char end inside start)))
    (org-table-widget-tests--with-org "Before\n| a |\n| b |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (org-table-widget-mode 1)
        (unwind-protect
            (let* ((org-table-widget-reveal-on-point nil)
                   (table (car (org-table-widget--tables)))
                   (overlay (org-table-widget--display-table
                             (car table) (cdr table) (selected-window) 80))
                   (places `((before . ,(point-min)) (start . ,(car table))
                             (inside . ,(+ (car table) 3)) (end . ,(cdr table))))
                   (this-command (nth 0 case)))
              (goto-char (alist-get (nth 1 case) places))
              (run-hooks 'pre-command-hook)
              (goto-char (alist-get (nth 2 case) places))
              (run-hooks 'post-command-hook)
              (ert-info ((format "%S" case))
                (should (= (point) (alist-get (nth 3 case) places)))
                (should (overlay-buffer overlay))
                (should-not org-table-widget--inside-table)))
          (org-table-widget-mode -1))))))

(ert-deftest org-table-widget-rest-reveals-search-match ()
  (org-table-widget-tests--with-org "Before\n| key |\n| value |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-table-widget-mode 1)
      (unwind-protect
          (let* ((org-table-widget-reveal-on-point nil)
                 (table (car (org-table-widget--tables)))
                 (overlay (org-table-widget--display-table
                           (car table) (cdr table) (selected-window) 80))
                 (this-command 'isearch-printing-char))
            (run-hooks 'pre-command-hook)
            (search-forward "value")
            ;; Isearch keeps point on its match by disabling adjustment.
            (let ((disable-point-adjustment t))
              (run-hooks 'post-command-hook))
            (should (looking-back "value" 5))
            (should-not (overlay-buffer overlay))
            (should org-table-widget--inside-table))
        (org-table-widget-mode -1)))))

(ert-deftest org-table-widget-edit-reveals-until-point-leaves ()
  (org-table-widget-tests--with-org "Before\n| a | b |\n| c | d |\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (org-table-widget-tests--with-pixel-mocks
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
          (let ((org-table-widget-reveal-on-point nil)
                (org-table-widget-relayout-delay 3600)
                (start (caar (org-table-widget--tables))))
            (unwind-protect
                (progn
                  (org-table-widget-mode 1)
                  (goto-char start)
                  (org-table-widget--post-command)
                  (should (org-table-widget--overlay-at start))
                  (should (eq (key-binding "e") #'org-table-widget-edit))
                  (call-interactively (key-binding "e"))
                  (should-not org-table-widget--overlays)
                  (should org-table-widget--inside-table)
                  (should (= (point) start))
                  (should-not (eq (key-binding "e") #'org-table-widget-edit))
                  ;; A relayout while the source is being edited keeps it.
                  (org-table-widget-refresh)
                  (should-not org-table-widget--overlays)
                  (forward-line 1)
                  (org-table-widget--post-command)
                  (should-not org-table-widget--overlays)
                  (goto-char (point-max))
                  (org-table-widget--post-command)
                  (should (org-table-widget--overlay-at start))
                  (should-not org-table-widget--inside-table)
                  ;; Toggling the revealed source back rests on the widget.
                  (goto-char start)
                  (org-table-widget-toggle)
                  (should-not org-table-widget--overlays)
                  (forward-line 1)
                  (org-table-widget-toggle)
                  (should (= (point) start))
                  (should (org-table-widget--overlay-at start))
                  (should-error (progn (goto-char (point-min))
                                       (org-table-widget-edit))
                                :type 'user-error)
                  ;; Enabling with point in the source leaves that table as source.
                  (org-table-widget-mode -1)
                  (goto-char (1+ start))
                  (org-table-widget-mode 1)
                  (should-not org-table-widget--overlays)
                  (org-table-widget--post-command)
                  (goto-char (point-max))
                  (org-table-widget--post-command)
                  (should (org-table-widget--overlay-at start)))
              (org-table-widget-mode -1))))))))

(ert-deftest org-table-widget-rest-vertical-interactive ()
  ;; Redisplay is required: batch line motion ignores the widget's geometry.
  (skip-unless (not noninteractive))
  (dolist (visual '(nil t))
    (org-table-widget-tests--with-org "Before\n| a |\n| b |\n| c |\nAfter\n"
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (when visual (visual-line-mode 1))
        (let ((org-table-widget-reveal-on-point nil))
          (org-table-widget-mode 1)
          (unwind-protect
              (let* ((table (car (org-table-widget--tables)))
                     (overlay (or (org-table-widget--overlay-at (car table))
                                  (org-table-widget--display-table
                                   (car table) (cdr table) (selected-window) 80)))
                     stops)
                (goto-char (point-min))
                (dolist (command '(next-line next-line previous-line previous-line))
                  (redisplay t)
                  (let ((this-command command))
                    (run-hooks 'pre-command-hook)
                    (call-interactively command)
                    (run-hooks 'post-command-hook))
                  (push (point) stops))
                (should (equal (nreverse stops)
                               (list (car table) (cdr table)
                                     (car table) (point-min))))
                (should (overlay-buffer overlay)))
            (org-table-widget-mode -1)))))))

(ert-deftest org-table-widget-tables-skips-table-el ()
  (org-table-widget-tests--with-org "text\n| a |\n| b |\n\n+---+\n| c |\n+---+\n\n| d |\n"
    (let ((tables (org-table-widget--tables)))
      (should (equal (length tables) 2)))))

(ert-deftest org-table-widget-mode-requires-org ()
  (with-temp-buffer
    (should-error (org-table-widget-mode 1) :type 'user-error)
    (should-not org-table-widget-mode)))

(ert-deftest org-table-widget-mode-without-window-keeps-buffer-clean ()
  (org-table-widget-tests--with-org "| a |\n| b |\n"
    (set-buffer-modified-p nil)
    (org-table-widget-mode 1)
    (should-not (buffer-modified-p))
    (should (markerp org-table-widget--previous-point))
    (should (memq #'org-table-widget--pre-command pre-command-hook))
    (org-table-widget-mode -1)
    (should-not org-table-widget--previous-point)
    (should-not (memq #'org-table-widget--pre-command pre-command-hook))
    (should-not org-table-widget--overlays)))

(ert-deftest org-table-widget-overlay-preserves-pixel-spaces-and-newlines ()
  (require 'textui)
  (dolist (source '("| a | longer |\n| b | x |\n"
                    "| a | longer |\n| b | x |"))
    (org-table-widget-tests--with-org source
                                      (org-table-widget-tests--with-pixel-mocks
                                       (font-lock-ensure)
                                       (set-buffer-modified-p nil)
                                       (let* ((before (buffer-string))
                                              (undo buffer-undo-list)
                                              (overlay (org-table-widget--display-table
                                                        (point-min) (point-max) (selected-window) 80))
                                              (rendered (overlay-get overlay 'before-string)))
                                         ;; Point can rest only before a non-empty replacement.
                                         (should (equal (overlay-get overlay 'display)
                                                        (if (string-suffix-p "\n" source) "\n" " ")))
                                         (should (stringp rendered))
                                         (should (text-property-any 0 (length rendered)
                                                                    'org-table-widget-spacing t rendered))
                                         (should-not (string-suffix-p "\n" rendered))
                                         (should (get-text-property 0 'cursor rendered))
                                         (should (eq (overlay-get overlay 'keymap)
                                                     org-table-widget-map))
                                         (should (= (length org-table-widget--overlays) 1))
                                         (should (eq overlay (org-table-widget--overlay-at (point-min))))
                                         (should (eq overlay (org-table-widget--overlay-at (1- (point-max)))))
                                         (should-not (org-table-widget--overlay-at (point-max)))
                                         (org-table-widget--remove-overlay overlay)
                                         (should-not (overlay-buffer overlay))
                                         (should-not org-table-widget--overlays)
                                         (should (equal-including-properties before (buffer-string)))
                                         (should (eq undo buffer-undo-list))
                                         (should-not (buffer-modified-p)))))))

(ert-deftest org-table-widget-overlay-lifecycle ()
  (org-table-widget-tests--with-org "Before\n| a | longer |\n\nAfter\n| b | c |\n"
                                    (save-window-excursion
                                      (switch-to-buffer (current-buffer))
                                      (org-table-widget-tests--with-pixel-mocks
                                       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
                                         (font-lock-ensure)
                                         (buffer-enable-undo)
                                         (set-buffer-modified-p nil)
                                         (let ((before (buffer-string))
                                               (undo buffer-undo-list)
                                               (org-table-widget-reveal-on-point t)
                                               (org-table-widget-relayout-delay 0))
                                           (unwind-protect
                                               (progn
                                                 (org-table-widget-mode 1)
                                                 (should (= (length org-table-widget--overlays) 2))
                                                 (let ((old (copy-sequence org-table-widget--overlays)))
                                                   (org-table-widget-refresh)
                                                   (should (seq-every-p
                                                            (lambda (overlay) (not (overlay-buffer overlay)))
                                                            old)))
                                                 (goto-char (caar (org-table-widget--tables)))
                                                 (org-table-widget--post-command)
                                                 (should-not (org-table-widget--overlay-at (point)))
                                                 (should (= (length org-table-widget--overlays) 1))
                                                 (goto-char (point-min))
                                                 (org-table-widget--post-command)
                                                 (should (= (length org-table-widget--overlays) 2))
                                                 (goto-char (caar (org-table-widget--tables)))
                                                 (org-table-widget-toggle)
                                                 (should-not (org-table-widget--overlay-at (point)))
                                                 (org-table-widget-toggle)
                                                 (should (= (length org-table-widget--overlays) 2))
                                                 ;; Force the same callback that a changed window width uses.
                                                 (let ((old (copy-sequence org-table-widget--overlays)))
                                                   (setq org-table-widget--width 1)
                                                   (org-table-widget--window-changed)
                                                   (should (= (length org-table-widget--overlays) 2))
                                                   (should (seq-every-p
                                                            (lambda (overlay) (not (overlay-buffer overlay)))
                                                            old)))
                                                 (let ((old (copy-sequence org-table-widget--overlays)))
                                                   (org-table-widget-mode -1)
                                                   (should-not org-table-widget--overlays)
                                                   (should (seq-every-p
                                                            (lambda (overlay) (not (overlay-buffer overlay)))
                                                            old)))
                                                 (should (equal-including-properties before (buffer-string)))
                                                 (should (eq undo buffer-undo-list))
                                                 (should-not (buffer-modified-p)))
                                             (org-table-widget-mode -1))))))))

(ert-deftest org-table-widget-overlay-reveals-on-modification ()
  (require 'textui)
  (dolist (offset '(0 3))
    (org-table-widget-tests--with-org "| a | longer |\n"
                                      (org-table-widget-tests--with-pixel-mocks
                                       (let ((overlay (org-table-widget--display-table
                                                       (point-min) (point-max) (selected-window) 80)))
                                         (goto-char (+ (point-min) offset))
                                         (insert "x")
                                         (should-not (overlay-buffer overlay))
                                         (should-not org-table-widget--overlays))))))

(ert-deftest org-table-widget-parse-column-group-metadata ()
  (org-table-widget-tests--with-org
      "| / | < | > | <> | |\n| Name | A | B | C | D |\n|---+---+---+---+---|\n| x | 1 | 2 | 3 | 4 |\n"
    (let ((table (org-table-widget--parse (point-min) (point-max))))
      (should (= (plist-get table :header-rows) 1))
      (should (= (length (plist-get table :rows)) 3))
      (should (equal (caar (plist-get table :rows)) "Name")))))

(ert-deftest org-table-widget-parse-metadata-only-is-empty ()
  (dolist (source '("| / | <> | |\n"
                    "|---+---|\n| / | <> |\n| <l> | <r> |\n|---+---|\n"))
    (org-table-widget-tests--with-org source
      (should-not (org-table-widget--parse (point-min) (point-max))))))

(ert-deftest org-table-widget-parse-slash-data-is-not-metadata ()
  (org-table-widget-tests--with-org "| / | ordinary data |\n"
    (should (equal (caar (plist-get (org-table-widget--parse
                                    (point-min) (point-max)) :rows)) "/"))))

(ert-deftest org-table-widget-measure-cache-keeps-properties-and-owns-keys ()
  (with-temp-buffer
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((calls 0)
            (plain "text")
            (styled (propertize "text" 'face 'bold)))
        (cl-letf (((symbol-function 'org-table-widget--measure-string)
                   (lambda (string _window)
                     (cl-incf calls)
                     (if (get-text-property 0 'face string) 20 10))))
          (org-table-widget--with-cached-measurements (selected-window)
            (should (= 10 (org-table-widget--measure-string plain nil)))
            (should (= 20 (org-table-widget--measure-string styled nil)))
            (should (= 20 (org-table-widget--measure-string (copy-sequence styled) nil)))
            (should (= calls 2))
            (remove-text-properties 0 4 '(face nil) styled)
            (should (= 10 (org-table-widget--measure-string styled nil)))
            (let ((before calls))
              (should (= 20 (org-table-widget--measure-string
                             (propertize "text" 'face 'bold) nil)))
              (should (= calls before)))))))))

(ert-deftest org-table-widget-measure-cache-invalidates-on-font-remapping ()
  (with-temp-buffer
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((cache (org-table-widget--measurements (selected-window))))
        (should (eq cache (org-table-widget--measurements (selected-window))))
        (setq-local face-remapping-alist '((default (:height 1.2) default)))
        (should-not (eq cache (org-table-widget--measurements (selected-window))))))))

(ert-deftest org-table-widget-layout-gc-threshold-is-dynamically-scoped ()
  (require 'textui)
  (org-table-widget-tests--with-org "| a |\n"
    (let ((gc-cons-threshold 800000)
          observed)
      (cl-letf (((symbol-function 'textui-layout-widget)
                 (lambda (&rest _)
                   (setq observed gc-cons-threshold)
                   (error "Test layout failure"))))
        (should-error (org-table-widget--display-table
                       (point-min) (point-max) (selected-window) 80))
        (should (= observed (* 64 1024 1024)))
        (should (= gc-cons-threshold 800000))))))

(ert-deftest org-table-widget-render-cache-reuses-and-invalidates ()
  (require 'textui)
  (org-table-widget-tests--with-org "Before\n| a | longer |\n| b | x |\n\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((calls 0)
            (width 80)
            (font 1)
            (layout (symbol-function 'textui-layout-widget))
            (org-table-widget-reveal-on-point t)
            (org-table-widget-relayout-delay 3600))
        (org-table-widget-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                    ((symbol-function 'org-table-widget--layout-width)
                     (lambda (_window) width))
                    ((symbol-function 'org-table-widget--font-signature)
                     (lambda (_window) (list font)))
                    ((symbol-function 'textui-layout-widget)
                     (lambda (widget columns)
                       (cl-incf calls)
                       (funcall layout widget columns))))
            (unwind-protect
                (progn
                  (org-table-widget-mode 1)
                  (should (= calls 1))
                  (let ((rendered (overlay-get (car org-table-widget--overlays)
                                               'before-string)))
                    (org-table-widget-refresh)
                    (should (= calls 1))
                    (should (eq rendered (overlay-get
                                          (car org-table-widget--overlays)
                                          'before-string))))
                  (goto-char (caar (org-table-widget--tables)))
                  (org-table-widget--post-command)
                  (should-not org-table-widget--overlays)
                  (goto-char (point-min))
                  (org-table-widget--post-command)
                  (should (= calls 1))
                  (setq font 2)
                  (org-table-widget-refresh)
                  (should (= calls 2))
                  (setq width 60)
                  (org-table-widget-refresh)
                  (should (= calls 3))
                  (let ((org-table-widget-use-unicode-borders nil))
                    (org-table-widget-refresh)
                    (should (= calls 4)))
                  (goto-char (caar (org-table-widget--tables)))
                  (org-table-widget--post-command)
                  (search-forward "a")
                  (insert " edited")
                  (should-not org-table-widget--render-cache)
                  (goto-char (point-min))
                  (org-table-widget--post-command)
                  (should (= calls 5))
                  (should (string-match-p "edited" (overlay-get
                                                    (car org-table-widget--overlays)
                                                    'before-string)))
                  (insert "New paragraph\n")
                  (should-not org-table-widget--render-cache)
                  (goto-char (point-min))
                  (org-table-widget-refresh)
                  (should (= calls 6))
                  (should (= (length org-table-widget--overlays) 1)))
              (org-table-widget-mode -1)
              (should-not org-table-widget--render-cache)
              (should-not (memq #'org-table-widget--invalidate-render-cache
                                after-change-functions)))))))))

(ert-deftest org-table-widget-render-cache-checks-source-properties ()
  (require 'textui)
  (org-table-widget-tests--with-org "| a |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((calls 0))
        (cl-letf (((symbol-function 'font-lock-ensure) #'ignore)
                  ((symbol-function 'textui-layout-widget)
                   (lambda (&rest _) (cl-incf calls) "rendered")))
          (org-table-widget--display-table (point-min) (point-max) (selected-window) 80)
          (org-table-widget--clear)
          ;; No live overlay and the mode is off: the key itself must detect
          ;; property-only changes, not just an invalidation hook.
          (put-text-property 3 4 'face 'bold)
          (org-table-widget--display-table (point-min) (point-max) (selected-window) 80)
          (should (= calls 2)))))))

(ert-deftest org-table-widget-measure-preserves-source-when-point-moves ()
  (dolist (fail '(nil t))
    (with-temp-buffer
      (insert "Keep source bytes\n")
      (buffer-enable-undo)
      (set-buffer-modified-p nil)
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (let ((before (buffer-string)) (undo buffer-undo-list))
          (cl-letf (((symbol-function 'window-text-pixel-size)
                     (lambda (&rest _)
                       (goto-char (point-min))
                       (if fail (error "Test measurement failure") '(10 . 10)))))
            (if fail
                (should-error (org-table-widget--measure-string "probe" (selected-window)))
              (should (= 10 (org-table-widget--measure-string "probe" (selected-window)))))
            (should (equal-including-properties before (buffer-string)))
            (should (eq undo buffer-undo-list))
            (should-not (buffer-modified-p))))))))

(ert-deftest org-table-widget-measure-ignores-line-numbers ()
  (with-temp-buffer
    (insert "Source\n")
    (setq-local display-line-numbers t)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let (numbers)
        (cl-letf (((symbol-function 'window-text-pixel-size)
                   (lambda (&rest _)
                     (push display-line-numbers numbers)
                     '(10 . 10))))
          (should (= 10 (org-table-widget--measure-string "probe"
                                                          (selected-window))))
          (should (equal numbers '(nil)))
          (should (eq display-line-numbers t)))))))

(ert-deftest org-table-widget-prefix-reduces-layout-budgets-and-invalidates-cache ()
  (require 'textui)
  (org-table-widget-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max)) seen)
        (org-table-widget-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
                    ;; Both fringes shown: no continuation column is kept.
                    ((symbol-function 'org-table-widget--reserves-continuation-p)
                     #'ignore)
                    ((symbol-function 'font-lock-ensure) #'ignore)
                    ((symbol-function 'textui-layout-widget)
                     (lambda (widget width)
                       (push (list width (widget-get widget :pixel-budget)) seen)
                       "rendered")))
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))
            (setq-local line-prefix "  ")
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(78 780)))
            ;; Text properties take precedence over buffer-local variables.
            (put-text-property beg end 'line-prefix "    ")
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(76 760)))
            (setq-local wrap-prefix "      ")
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(74 740)))
            (put-text-property beg end 'wrap-prefix "   ")
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(76 760)))
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (= 5 (length seen)))
            (setq-local line-prefix nil wrap-prefix nil)
            (remove-text-properties beg end '(line-prefix nil wrap-prefix nil))
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))))))))

(ert-deftest org-table-widget-continuation-column-reduces-layout-budget ()
  (skip-unless (boundp 'overflow-newline-into-fringe))
  (require 'textui)
  (org-table-widget-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max)) (fringes '(8 8 nil nil)) seen)
        (org-table-widget-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
                    ((symbol-function 'window-fringes)
                     (lambda (&rest _) fringes))
                    ((symbol-function 'font-lock-ensure) #'ignore)
                    ((symbol-function 'textui-layout-widget)
                     (lambda (widget width)
                       (push (list width (widget-get widget :pixel-budget)) seen)
                       "rendered")))
            (let ((overflow-newline-into-fringe t))
              (org-table-widget--display-table beg end (selected-window) 80)
              (should (equal (car seen) '(80 800)))
              ;; Without either fringe the continuation glyph takes the
              ;; last column, and the cached full-width layout is dropped.
              (dolist (without '((0 0 nil nil) (8 0 nil nil) (0 8 nil nil)))
                (setq fringes without)
                (org-table-widget--display-table beg end (selected-window) 80)
                (should (equal (car seen) '(79 790)))))
            (setq fringes '(8 8 nil nil))
            (let ((overflow-newline-into-fringe nil))
              (org-table-widget--display-table beg end (selected-window) 80)
              (should (equal (car seen) '(79 790))))
            ;; One layout with and one without the reserved column.
            (should (= 2 (length seen)))))))))

(ert-deftest org-table-widget-line-numbers-reduce-layout-budget ()
  (require 'textui)
  (org-table-widget-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max))
            (numbers '(50 . 3)) (body-height 20) seen)
        (org-table-widget-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
                    ((symbol-function 'org-table-widget--reserves-continuation-p)
                     #'ignore)
                    ((symbol-function 'line-number-display-width)
                     (lambda (&optional pixelwise)
                       (if pixelwise (car numbers) (cdr numbers))))
                    ((symbol-function 'window-body-height)
                     (lambda (&rest _) body-height))
                    ((symbol-function 'font-lock-ensure) #'ignore)
                    ((symbol-function 'textui-layout-widget)
                     (lambda (widget width)
                       (push (list width (widget-get widget :pixel-budget)) seen)
                       "rendered")))
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))
            (setq-local display-line-numbers t)
            ;; Three digits and two blanks of 10 px each; no reachable line
            ;; (2 + 20 + 5) needs more digits.
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(75 750)))
            ;; Two digits fit the current window start, but scrolling can
            ;; reach line 2 + 93 + 5 = 100: reserve five 12 px glyphs.
            (setq numbers '(48 . 2) body-height 93)
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(74 740)))
            (setq-local display-line-numbers nil)
            (org-table-widget--display-table beg end (selected-window) 80)
            (should (equal (car seen) '(80 800)))))))))

(ert-deftest org-table-widget-line-number-toggle-schedules-relayout ()
  (org-table-widget-tests--with-org "| a |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((org-table-widget-relayout-delay 3600))
        (org-table-widget-mode 1)
        (unwind-protect
            (progn
              (should-not org-table-widget--timer)
              (display-line-numbers-mode 1)
              (should org-table-widget--timer))
          (display-line-numbers-mode -1)
          (org-table-widget-mode -1))
        (should-not org-table-widget--timer)
        (should-not (memq #'org-table-widget--schedule-relayout
                          display-line-numbers-mode-hook))))))

(ert-deftest org-table-widget-prefix-measures-display-specifications ()
  (org-table-widget-tests--with-org "| a |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((display '(space :width (23))) measured)
        (put-text-property (point-min) (point-max) 'line-prefix
                           (propertize " " 'display display))
        (setq-local wrap-prefix '(space :width (17)))
        (cl-letf (((symbol-function 'org-table-widget--measure-string)
                   (lambda (string _window)
                     (push (get-text-property 0 'display string) measured)
                     (if (equal (car measured) display) 23 17))))
          (should (= 23 (org-table-widget--prefix-width
                         (point-min) (selected-window))))
          (should (equal measured '((space :width (17)) (space :width (23))))))))))

(ert-deftest org-table-widget-revert-does-not-duplicate-previews ()
  "Repeated real file reverts keep one preview and leave source unchanged."
  (let ((file (make-temp-file "otw-revert-" nil ".org"
                              "Before\n| a | b |\n| c | d |\n\nAfter\n"))
        (org-mode-hook '(org-table-widget-mode))
        (org-table-widget-relayout-delay 3600))
    (unwind-protect
        (save-window-excursion
          (org-table-widget-tests--with-pixel-mocks
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
              (find-file file)
              (goto-char (point-min))
              (org-table-widget-refresh)
              (dolist (preserve-modes '(nil nil t nil t))
                (revert-buffer t t preserve-modes)
                (should org-table-widget-mode)
                (should (equal (buffer-string)
                               "Before\n| a | b |\n| c | d |\n\nAfter\n"))
                (should (= 1 (length org-table-widget--overlays)))
                (should (= 1 (length
                              (seq-filter
                               (lambda (ov) (overlay-get ov 'org-table-widget))
                               (append (car (overlay-lists))
                                       (cdr (overlay-lists)))))))))))
      (when-let* ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer (org-table-widget-mode -1))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest org-table-widget-major-mode-change-releases-owned-resources ()
  "Mode changes release previews, markers and timers, not other overlays."
  (org-table-widget-tests--with-org "Before\n| a | b |\n\nAfter\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((org-table-widget-relayout-delay 3600))
        (org-table-widget-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
            (unwind-protect
                (progn
                  (org-table-widget-mode 1)
                  (org-table-widget--pre-command)
                  (org-table-widget--schedule-relayout)
                  (let ((previews (copy-sequence org-table-widget--overlays))
                        (marker org-table-widget--previous-point)
                        (timer org-table-widget--timer)
                        (unrelated (make-overlay 1 3)))
                    (should previews)
                    (should (marker-position marker))
                    (should (timerp timer))
                    (fundamental-mode)
                    (should-not org-table-widget-mode)
                    (dolist (overlay previews)
                      (should-not (overlay-buffer overlay)))
                    (should-not (marker-position marker))
                    (should-not (memq timer timer-idle-list))
                    (should (eq (overlay-buffer unrelated) (current-buffer)))
                    (delete-overlay unrelated)))
              (org-table-widget-mode -1))))))))

(ert-deftest org-table-widget-disable-removes-major-mode-cleanup-hook ()
  "Explicit disable removes its buffer-local major-mode cleanup hook."
  (org-table-widget-tests--with-org "| a | b |\n"
    (org-table-widget-mode 1)
    (should (memq #'org-table-widget--before-major-mode-change
                  change-major-mode-hook))
    (org-table-widget-mode -1)
    (should-not (memq #'org-table-widget--before-major-mode-change
                      change-major-mode-hook))))

(provide 'org-table-widget-tests)
;;; org-table-widget-tests.el ends here
