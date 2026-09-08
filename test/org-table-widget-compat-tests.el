;;; org-table-widget-compat-tests.el --- Optional compatibility tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this file in a graphical Emacs with org-modern and its dependencies
;; on load-path, then run M-x ert RET org-table-widget-compat- RET.
;; These tests intentionally use real fontification, measurement and redisplay.

;;; Code:

(require 'ert)
(require 'org-table-widget)
(defvar org-modern-table)
(declare-function org-modern-mode "org-modern" (&optional arg))

(ert-deftest org-table-widget-compat-org-modern-enable-order ()
  (skip-unless (display-graphic-p))
  (skip-unless (require 'org-modern nil t))
  (dolist (via-hook '(nil t))
    (dolist (order '((org-modern-mode org-table-widget-mode)
                     (org-table-widget-mode org-modern-mode)))
      (with-temp-buffer
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (insert "* TODO Heading\n- [ ] Task\n\n| a |\n| b |\n")
          (goto-char (point-min))
          (let ((org-modern-table nil)
                (org-mode-hook (and via-hook order)))
            (unwind-protect
                (progn
                  (org-mode)
                  (unless via-hook
                    (dolist (mode order) (funcall mode 1)))
                  (dotimes (_ 2)
                    (font-lock-ensure)
                    (redisplay t)
                    (should (eq (get-text-property 3 'face) 'org-modern-todo))
                    (should (get-text-property 1 'display))
                    (should (get-text-property 18 'display))
                    (should (= (length org-table-widget--overlays) 1))
                    (org-table-widget-refresh)))
              (org-table-widget-mode -1)
              (org-modern-mode -1))))))))

(provide 'org-table-widget-compat-tests)
;;; org-table-widget-compat-tests.el ends here
