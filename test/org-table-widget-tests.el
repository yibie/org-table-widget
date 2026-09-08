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
     ;; "id" needs 20 + 20 padding, "status" 60 + 20; a column whose
     ;; natural width equals its minimum keeps weight 1, so it may
     ;; receive a pixel of the flexible space.
     (should (<= 40 (nth 0 widths) 42))
     (should (<= 80 (nth 1 widths) 82))
     (should (> (nth 2 widths) 800)))))

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
            (let* ((table (car (org-table-widget--tables)))
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
            (let* ((table (car (org-table-widget--tables)))
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
              (let ((table (car (org-table-widget--tables))))
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
                                         (should (equal (overlay-get overlay 'display) ""))
                                         (should (stringp rendered))
                                         (should (text-property-any 0 (length rendered)
                                                                    'org-table-widget-spacing t rendered))
                                         (should (eq (string-suffix-p "\n" rendered)
                                                     (string-suffix-p "\n" source)))
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

(ert-deftest org-table-widget-prefix-reduces-layout-budgets-and-invalidates-cache ()
  (require 'textui)
  (org-table-widget-tests--with-org "| a | b |\n"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((beg (point-min)) (end (point-max)) seen)
        (org-table-widget-tests--with-pixel-mocks
          (cl-letf (((symbol-function 'window-font-width) (lambda (&rest _) 10))
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

(provide 'org-table-widget-tests)
;;; org-table-widget-tests.el ends here
