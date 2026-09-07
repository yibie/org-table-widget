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
    (org-table-widget-mode -1)
    (should-not org-table-widget--overlays)))

(provide 'org-table-widget-tests)
;;; org-table-widget-tests.el ends here
