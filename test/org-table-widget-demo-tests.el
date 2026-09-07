;;; org-table-widget-demo-tests.el --- Scenario checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Load after org-table-widget-tests.el, then run all ERT tests.
;; Known rendering failures deliberately remain failures, not expected failures.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'org-table-widget-tests)

(defconst org-table-widget-demo-tests--directory
  (expand-file-name "../demos" (file-name-directory
                                (or load-file-name buffer-file-name)))
  "Directory containing scenario fixtures.")

(defun org-table-widget-demo-tests--check (file)
  "Check table overlays and buffer invariants for demo FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (org-fold-show-all)
    (goto-char (point-min))
    (buffer-enable-undo)
    (set-buffer-modified-p nil)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((before (buffer-substring-no-properties (point-min) (point-max)))
             (undo buffer-undo-list)
             ;; Independent discovery: Org's AST excludes example blocks.
             (tables (org-element-map (org-element-parse-buffer) 'table
                                      (lambda (table)
                                        (when (eq (org-element-property :type table) 'org)
                                          (org-element-property :post-affiliated table)))))
             (org-table-widget-reveal-on-point nil)
             problems)
        (unwind-protect
            (org-table-widget-tests--with-pixel-mocks
              (cl-letf (((symbol-function 'display-graphic-p)
                         (lambda (&rest _) t))
                        ((symbol-function 'org-table-widget--layout-width)
                         (lambda (_window) 120)))
                (org-table-widget-mode 1)
                (should (equal before (buffer-substring-no-properties
                                       (point-min) (point-max))))
                (should-not (buffer-modified-p))
                (should (eq undo buffer-undo-list))
                (let ((starts (sort (mapcar #'overlay-start
                                            org-table-widget--overlays) #'<)))
                  (unless (equal starts tables)
                    (push (list :expected-table-starts tables :actual starts)
                          problems)))
                (dolist (overlay org-table-widget--overlays)
                  (let* ((beg (overlay-start overlay))
                         (end (overlay-end overlay))
                         (source-rows (count-lines beg end))
                         (rendered (overlay-get overlay 'before-string))
                         (lines (length (split-string
                                         (string-trim-right rendered "\n") "\n"))))
                    (unless (>= lines source-rows)
                      (push (list :line (line-number-at-pos beg)
                                  :source-rows source-rows :rendered-lines lines)
                            problems))))
                (ert-info ((format "%s: %S" (file-name-nondirectory file)
                                   (reverse problems)))
                          (should-not problems))))
          (org-table-widget-mode -1))))))

(dolist (file (directory-files org-table-widget-demo-tests--directory
                               t "\\.org\\'"))
  (unless (equal (file-name-nondirectory file) "huge.org")
    (eval `(ert-deftest ,(intern (concat "org-table-widget-demo-"
                                         (file-name-base file))) ()
             (org-table-widget-demo-tests--check ,file)) t)))
(ert-deftest org-table-widget-demo-formula-recalculation ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "formulas.org" org-table-widget-demo-tests--directory))
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "^#\\+TBLFM:")
    (org-ctrl-c-ctrl-c)
    (goto-char (point-min))
    (re-search-forward "^| Item")
    (let ((actual (org-table-to-lisp)))
      (re-search-forward "^#\\+NAME: invoice-recalculated")
      (re-search-forward "^| Item")
      (should (equal actual (org-table-to-lisp))))))
(ert-deftest org-table-widget-demo-column-groups-are-metadata ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "groups-and-rules.org" org-table-widget-demo-tests--directory))
    (org-mode)
    (let* ((bounds (nth 1 (org-table-widget--tables)))
           (table (org-table-widget--parse (car bounds) (cdr bounds))))
      ;; Org's / row declares column groups; it is not a header/data row.
      (should (= (plist-get table :header-rows) 1))
      (should-not (equal (caar (plist-get table :rows)) "/")))))

(provide 'org-table-widget-demo-tests)
;;; org-table-widget-demo-tests.el ends here
