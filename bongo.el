;;; bongo.el --- buffer-oriented media player for Emacs
;; Copyright (C) 2005, 2006  Daniel Brockman
;; Copyright (C) 2006  Daniel Jensen
;; Copyright (C) 2005  Lars Öhrman
;; Copyright (C) 1998, 2000, 2001, 2002, 2003, 2004, 2005
;;   Free Software Foundation, Inc.

;; Author: Daniel Brockman <daniel@brockman.se>
;; URL: http://www.brockman.se/software/bongo/
;; Created: September 3, 2005
;; Updated: December 2, 2006

;; This file is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of
;; the License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public
;; License along with this program (see the file `COPYING');
;; if not, write to the Free Software Foundation, 51 Franklin
;; Street, Fifth Floor, Boston, MA 02110-1301, USA.

;;; Commentary:

;; The `lastfm-submit' library, necessary for Last.fm
;; functionality, is available at the following URL:

;; <http://www.brockman.se/software/lastfm-submit.el>

;;; Todo:

;; Better support for streaming media.  Bongo should be able
;; to parse metadata provided by streaming media servers.

;; Shuffle operations.  It would be nice to have both a
;; random shuffle operation and an interleaving
;; enqueue operation.

;; Sorting operations.

;; Implement `bongo-file-name-roots' so that forcer can try
;; out Bongo. :-)

;; Fix `E' when the playing song is not in the playlist.

;; Customizing `bongo-header-line-mode' should have
;; immediate effect on existing Bongo playlist buffers.

;; Fix bug related to collapsing the section containing the
;; currently playing track.

;; Prevent the header line from flashing away and back when
;; going from one track to the next.

;; Implement scrolling for the header line.

;; Better error messages when players fail.

;; Cache metadata?  Maybe even make it editable?  This would
;; be a good way to let the user put titles on URLs.

;; The user should have a way to say ``play this track using
;; that backend.''

;; Generalize intra-playlist queue.

;; Implement intra-track region repeat.

;; Install audio CD functionality by Daniel Jensen.

;; Provide a way to switch to the playlist by clicking on
;; something in the mode line.

;; Provide a way to easily change `bongo-next-action'.

;; Allow pseudo-tracks that perform some action when played
;; instead of actually starting a player backend.  You could
;; have a pseudo-track that would stop playback, for example,
;; or one that would change the value of `bongo-next-action'.

;; Phase out `bongo-avoid-interrupting-playback'.  Giving a
;; prefix argument N to `bongo-stop' should insert a stop
;; sentinel pseudo-track after the Nth next track.

;; Provide a way to specify that intermediate headers
;; (cf. `bongo-insert-intermediate-headers') should be
;; inserted even for singleton albums.

;;; Code:

;; We try to load this library so that we can later decide
;; whether to enable Bongo Last.fm mode by default.
(require 'lastfm-submit nil 'no-error)

(eval-when-compile
  (require 'cl)
  (require 'rx))

(defgroup bongo nil
  "Buffer-oriented media player."
  :prefix "bongo-"
  :group 'multimedia
  :group 'applications)


;;;; Macro definitions

(defmacro with-bongo-buffer (&rest body)
  "Execute the forms in BODY in some Bongo buffer.
The value returned is the value of the last form in BODY.

If the current buffer is not a Bongo buffer, switch to
the buffer returned by the function `bongo-buffer'."
  (declare (indent 0) (debug t))
  `(with-current-buffer
       (if (bongo-buffer-p)
           (current-buffer)
         (bongo-buffer))
     ,@body))

(defmacro with-bongo-library-buffer (&rest body)
  "Execute the forms in BODY in some Bongo library buffer.
The value returned is the value of the last form in BODY.

If the current buffer is not a library buffer, switch to
the buffer returned by the function `bongo-library-buffer'."
  (declare (indent 0) (debug t))
  `(with-current-buffer
       (if (bongo-library-buffer-p)
           (current-buffer)
         (bongo-library-buffer))
     ,@body))

(defmacro with-bongo-playlist-buffer (&rest body)
  "Execute the forms in BODY in some Bongo playlist buffer.
The value returned is the value of the last form in BODY.

If the current buffer is not a playlist buffer, switch to
the buffer returned by the function `bongo-playlist-buffer'."
  (declare (indent 0) (debug t))
  `(with-current-buffer
       (if (bongo-playlist-buffer-p)
           (current-buffer)
         (bongo-playlist-buffer))
     ,@body))

(defmacro with-point-at-bongo-track (point &rest body)
  "Execute BODY with point at the Bongo track line at POINT.
If there is no track at POINT, use the next track line.
If there is no next track line, signal an error."
  (declare (indent 1) (debug t))
  `(save-excursion
     (bongo-goto-point ,point)
     (when line-move-ignore-invisible
       (bongo-skip-invisible))
     (let ((line-move-ignore-invisible nil))
       (when (not (bongo-track-line-p))
         (bongo-goto-point (bongo-point-at-next-track-line)))
       (when (not (bongo-track-line-p))
         (error "No track at point"))
       ,@body)))

(defmacro bongo-ignore-movement-errors (&rest body)
  "Execute BODY; if a Bongo movement error occurs, return nil.
Otherwise, return the value of the last form in BODY."
  (declare (indent 0) (debug t))
  `(condition-case nil
       (progn ,@body)
     (bongo-movement-error nil)))

(defmacro bongo-until (test &rest body)
  "If TEST yields nil, evaluate BODY... and repeat.
The order of execution is thus TEST, BODY..., TEST, BODY..., TEST,
  and so on, until TEST returns non-nil.
Return the final value of TEST.

\(fn TEST BODY...)"
  (declare (indent 1) (debug t))
  (let ((result (gensym)))
    `(let (,result)
       (while (unless (setq ,result ,test)
                (prog1 t
                  ,@body)))
       ,result)))


;;;; Customization variables

(defvar bongo-backends '()
  "List of names of available Bongo player backends.
The backend data for each entry is stored in the `bongo-backend'
property of the backend name symbol.")

(defvar bongo-backend-matchers '()
  "List of Bongo player backend matchers.
See `bongo-custom-backend-matchers' for more information.")

(defcustom bongo-enabled-backends nil
  "(dummy declaration)" :group 'bongo)
(defcustom bongo-custom-backend-matchers nil
  "(dummy declaration)" :group 'bongo)

(defun bongo-evaluate-backend-defcustoms ()
  "Define `bongo-enabled-backends' and `bongo-custom-backend-matchers'.
This should be done whenever `bongo-backends' changes, so that
the `defcustom' options can be updated."
  (custom-declare-variable 'bongo-enabled-backends
    `',(apply 'nconc
              (mapcar (lambda (backend-name)
                        (when (executable-find
                               (bongo-backend-program-name
                                (bongo-backend backend-name)))
                          (list backend-name)))
                      bongo-backends))
    "List of names of enabled Bongo player backends.
See `bongo-backends' for a list of available backends."
    :type `(list (set :inline t :format "%v"
                      ,@(mapcar (lambda (backend-name)
                                  `(const :tag ,(bongo-backend-pretty-name
                                                 backend-name)
                                          ,backend-name))
                                bongo-backends)))
    :group 'bongo)
  (custom-reevaluate-setting 'bongo-enabled-backends)

  (custom-declare-variable 'bongo-custom-backend-matchers nil
    "List of custom Bongo player backend matchers.
Entries are rules of the form (BACKEND-NAME . MATCHER).

BACKEND-NAME is either `ignore' (which tells Bongo to ignore
  the matched files), or a symbol naming the backend to use.
MATCHER specifies which files the rule applies to;
  it is given to `bongo-file-name-matches-p'.

This option overrides `bongo-enabled-backends' in that disabled
backends will still be used if these rules say so.  In addition,
it always takes precedence over `bongo-backend-matchers'.

For example, let's say that you want to use mplayer instead of
mpg123 to play MP3 files, use speexdec to play \".speex\" files
in addition to \".spx\" files, and ignore WAV files altogether.
Then you could use the following setting:

   (setq bongo-custom-backend-matchers
         '((mplayer local-file \"mp3\")
           (speexdec local-file \"speex\")
           (ignore local-file \"wav\")))"
    :type
    `(repeat
      (cons :format "%v"
            (choice :tag "Backend"
                    (const :tag "Ignore matching files" ignore)
                    ,@(mapcar (lambda (backend-name)
                                (list 'const
                                      :tag (bongo-backend-pretty-name
                                            (bongo-backend backend-name))
                                      backend-name))
                              bongo-backends)
                    (symbol :tag "Other backend"))
            (cons :format "%v"
                  (repeat :tag "File types"
                          :value (local-file)
                          (choice :tag "Type"
                                  (const :tag "Local file" local-file)
                                  (string :tag "\
URI (specify scheme followed by a colon)")))
                  (choice :tag "Matcher"
                          (repeat :tag "File extensions" string)
                          (regexp :tag "File name (regexp)")
                          (function :tag "File name (predicate)")
                          (const :tag "All files" t)))))
    :group 'bongo))

(bongo-evaluate-backend-defcustoms)

(define-obsolete-variable-alias 'bongo-preferred-backends
  'bongo-custom-backend-matchers nil
  "This is an obsolete name for `bongo-custom-backend-matchers'.
Please read the documentation for that variable, as the new usage
differs slightly from the old.")

(defcustom bongo-prefer-library-buffers t
  "If non-nil, prefer library buffers over playlist buffers.
This affects what kind of buffer is created by `\\[bongo]' when there
are no existing Bongo buffers.

Regardless of this setting, you can a specific type of Bongo buffer
using `\\[bongo-library]' or `\\[bongo-playlist]'.  To create a new one,
simply create a new buffer and then switch to a Bongo mode using
`\\[bongo-library-mode]' or `\\[bongo-playlist-mode]'.

If you set this variable to nil, you can happily use Bongo without ever
seeing a library buffer (that is, unless you create one yourself)."
  :type 'boolean
  :group 'bongo)

(defcustom bongo-avoid-interrupting-playback nil
  "If non-nil, Bongo will not interrupt playback unless forced.
This affects playlist commands like `bongo-play-random'; to avoid
interrupting playback, they will merely change the playback order.

Most such commands take a prefix argument, which forces them to
interrupt playback if they normally wouldn't, or asks them not to
if they normally would.  (That is, the prefix argument makes the
command act as if this variable was temporarily toggled.)"
  :type 'boolean
  :group 'bongo)

(defcustom bongo-display-playlist-after-enqueue t
  "If non-nil, Bongo will display the playlist after enqueuing a track."
  :type 'boolean
  :group 'bongo)

(defcustom bongo-default-directory nil
  "Default directory for Bongo buffers, or nil."
  :type '(choice (const :tag "None in particular" nil)
                 directory)
  :group 'bongo
  :group 'bongo-file-names)

(defcustom bongo-confirm-flush-playlist t
  "If non-nil, ask for confirmation before flushing the playlist.
This affects only the command `bongo-flush-playlist'.
In particular, `bongo-erase-buffer' and `bongo-delete-played-tracks'
never ask for confirmation, regardless of the value of this variable."
  :type 'boolean
  :group 'bongo)

(defcustom bongo-default-playlist-buffer-name "*Bongo Playlist*"
  "The name of the default Bongo playlist buffer."
  :type 'string
  :group 'bongo)

(defcustom bongo-default-library-buffer-name "*Bongo Library*"
  "The name of the default Bongo library buffer."
  :type 'string
  :group 'bongo)

(defcustom bongo-next-action 'bongo-play-next-or-stop
  "The function to call after the current track finishes playing."
  :type '(choice
          (function-item :tag "Stop playback"
                         bongo-stop)
          (function-item :tag "Play the next track"
                         bongo-play-next-or-stop)
          (function-item :tag "Play the same track again"
                         bongo-replay-current)
          (function-item :tag "Play the previous track"
                         bongo-play-previous)
          (function-item :tag "Play a random track"
                         bongo-play-random))
  :group 'bongo)
(make-variable-buffer-local 'bongo-next-action)

(defvar bongo-stored-next-action nil
  "The old value of `bongo-next-action'.
This variable is used by `bongo-play-queued'.")

(defgroup bongo-file-names nil
  "File names and file name parsing in Bongo.
If your files do not have nice names but do have nice tags, then you
can use the `tree-from-tags.rb' tool (shipped with Bongo) to create a
hierarchy of nicely-named links to your files."
  :group 'bongo)

(defcustom bongo-file-name-field-separator " - "
  "String used to split track file names into fields.
For example, if your tracks are named like this,

   Frank Morton - 2004 - Frank Morton - 01 - Pojken på Tallbacksvägen.ogg

and your file name field separator is \" - \" (which is the default),
then the fields are \"Frank Morton\", \"2004\", \"Frank Morton\", \"01\",
and \"Pojken på Tallbacksvägen\".

When the the fields of a track's file name have been extracted,
they are used to build an infoset.

This is used by `bongo-default-infoset-from-file-name'."
  :type 'string
  :group 'bongo-file-names)

(defcustom bongo-file-name-album-year-regexp
  "\\`\\([0-9]\\{4\\}\\|'?[0-9]\\{2\\}\\)\\'"
  "Regexp matching album years.
This is used by `bongo-default-infoset-from-file-name'."
  :type 'regexp
  :group 'bongo-file-names)

(defcustom bongo-file-name-track-index-regexp "\\`[0-9]+\\'"
  "Regexp matching track indices.
This is used by `bongo-default-infoset-from-file-name'."
  :type 'regexp
  :group 'bongo-file-names)

(defcustom bongo-album-cover-file-names
  '("cover.jpg" "cover.jpeg" "cover.png"
    "front.jpg" "front.jpeg" "front.png"
    "album.jpg" "album.jpeg" "album.png")
  "File names of images that should be considered album covers.
See also `bongo-insert-album-covers'."
  :type '(repeat string)
  :group 'bongo-file-names)

(defcustom bongo-update-references-to-renamed-files 'ask
  "Whether to search all Bongo buffers after renaming a file.
If nil, never search through any buffers after renaming a file.
If `ask', ask the user every time.
If any other value, always perform the search.

You can rename a file from Bongo using `bongo-rename-line'."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Ask" ask)
                 (other :tag "Always" t))
  :group 'bongo
  :group 'bongo-file-names)

(defgroup bongo-display nil
  "Display of Bongo playlist and library buffers."
  :group 'bongo)

(defcustom bongo-field-separator (if (char-displayable-p ?—)
                                     " —— " " -- ")
  "String used to separate field values in track descriptions.
This is used by the function `bongo-default-format-field'."
  :type '(choice (const :tag " —— (Unicode dashes)" " —— ")
                 (const :tag " -- (ASCII dashes)" " -- ")
                 string)
  :group 'bongo-display)

(defcustom bongo-insert-album-covers (and window-system t)
  "Whether to put album cover images into Bongo buffers.
This is done by `bongo-insert-directory' and by
  `bongo-insert-directory-tree'.
See also `bongo-album-cover-file-names'."
  :type 'boolean
  :link '(custom-group-link bongo-file-names)
  :group 'bongo-display)

(defcustom bongo-join-inserted-tracks t
  "Whether to automatically join newly-inserted tracks.
This is done by repeatedly running `bongo-join'."
  :type 'boolean
  :group 'bongo-display)

(defcustom bongo-insert-intermediate-headers nil
  "Whether to automatically insert intermediate headers.
This is best explained by an example.  Say you have the
following section,

   [Frank Morton —— Frank Morton (2004)]
       01. Pojken på Tallbacksvägen
       02. Kanske det blir så att jag måste gå

and you insert the following section immediately afterwards.

   [Frank Morton —— Jag såg en film om en gammal man (2005)]
       01. Det är så mysigt att vara två
       02. Labyrinten

If this variable is nil, the result will be as follows:

   [Frank Morton —— Frank Morton (2004)]
       01. Pojken på Tallbacksvägen
       02. Kanske det blir så att jag måste gå
   [Frank Morton —— Jag såg en film om en gammal man (2005)]
       01. Det är så mysigt att vara två
       02. Labyrinten

On the other hand, if it is non-nil, the result will be as follows:

   [Frank Morton]
     [Frank Morton (2004)]
       01. Pojken på Tallbacksvägen
       02. Kanske det blir så att jag måste gå
     [Jag såg en film om en gammal man (2005)]
       01. Det är så mysigt att vara två
       02. Labyrinten

Notice that an intermediate header ``[Frank Morton]'' was inserted."
  :type 'boolean
  :group 'bongo-display)

(defcustom bongo-album-format "%t (%y)"
  "Template for displaying albums in Bongo.
This is used by the function `bongo-default-format-field'.
%t means the album title.
%y means the album year."
  :type 'string
  :group 'bongo-display)

(defcustom bongo-track-format "%i. %t"
  "Template for displaying tracks in Bongo.
This is used by the function `bongo-default-format-field'.
%t means the track title.
%i means the track index."
  :type 'string
  :group 'bongo-display)

(defcustom bongo-expanded-header-format "[%s]"
  "Template for displaying header lines for expanded sections.
%s means the header line content."
  :type 'string
  :group 'bongo-display)

(defcustom bongo-collapsed-header-format "[%s ...]"
  "Template for displaying header lines for collapsed sections.
%s means the header line content."
  :type 'string
  :group 'bongo-display)

(defcustom bongo-indentation-string "  "
  "String prefixed to lines once for each level of indentation."
  :type 'string
  :group 'bongo-display)

(defgroup bongo-header-line nil
  "Display of header lines in Bongo playlist buffers."
  :group 'bongo
  :group 'bongo-display)

(defcustom bongo-header-line-mode t
  "Display header lines in Bongo playlist buffers."
  :type 'boolean
  :initialize 'custom-initialize-default
  :set 'custom-set-minor-mode
  :group 'bongo-header-line)

(defcustom bongo-header-line-playing-string "Playing:"
  "String to display in the header line when a track is playing."
  :type 'string
  :group 'bongo-header-line)

(defcustom bongo-header-line-paused-string "Paused: "
  "String to display in the header line when a track is paused."
  :type 'string
  :group 'bongo-header-line)

(defun bongo-header-line-playback-status ()
  "Return the string to use for header line playback status."
  (when (bongo-playing-p)
    (if (bongo-paused-p)
        bongo-header-line-paused-string
      bongo-header-line-playing-string)))

(defcustom bongo-header-line-format
  '((bongo-header-line-playback-status) " "
    (bongo-formatted-infoset))
  "Template for Bongo playlist header lines.
Value is a list of expressions, each evaluating to a string or nil.
The values of the expressions are concatenated."
  :type '(repeat
          (choice
           (const :tag "Space" " ")
           string
           (const :tag "Playback status"
                  (bongo-header-line-playback-status))
           (const :tag "Track description"
                  (bongo-formatted-infoset))
           (sexp :tag "Value of arbitrary expression")))
  :group 'bongo-header-line)

(defvar bongo-header-line-string nil
  "Bongo header line string.
Value is derived from `bongo-header-line-format'.
The name of this variable should go in `header-line-format'.")
(make-variable-buffer-local 'bongo-header-line-string)

;; This is needed for text properties to work in the header line.
(put 'bongo-header-line-string 'risky-local-variable t)

(defun bongo-update-header-line-string (&rest dummy)
  "Update `bongo-header-line-string' using `bongo-header-line-format'.
If Bongo is not playing anything, set the header line string to nil.
Accept DUMMY arguments to ease hook usage."
  (when (bongo-buffer-p)
    (when (null header-line-format)
      (setq header-line-format '("")))
    (if bongo-header-line-mode
        (add-to-list 'header-line-format
          'bongo-header-line-string t)
      (setq header-line-format
            (remq 'bongo-header-line-string header-line-format)))
    (setq bongo-header-line-string
          (when (bongo-playing-p)
            (apply 'concat (mapcar 'eval bongo-header-line-format))))
    (when (or (equal header-line-format '(""))
              (and (equal header-line-format '("" bongo-header-line-string))
                   (null bongo-header-line-string)))
      (setq header-line-format nil))))

(defun bongo-header-line-mode (argument)
  "Toggle display of Bongo mode line indicator on or off.
With ARGUMENT equal to `toggle', or interactively
  with no prefix argument, toggle the mode.
With zero or negative ARGUMENT, turn the mode off.
With any other ARGUMENT, turn the mode on."
  ;; Use `toggle' rather than (if mode 0 1) so that using
  ;; `repeat-command' still does the toggling correctly.
  (interactive (list (or current-prefix-arg 'toggle)))
  (setq bongo-header-line-mode
        (if (eq argument 'toggle)
            (not bongo-header-line-mode)
          (> (prefix-numeric-value argument) 0)))
  (when (called-interactively-p)
    (customize-mark-as-set 'bongo-header-line-mode))
  (if bongo-header-line-mode
      (progn
        (add-hook 'bongo-player-started-functions
                  'bongo-update-header-line-string)
        (add-hook 'bongo-player-stopped-functions
                  'bongo-update-header-line-string)
        (add-hook 'bongo-player-paused/resumed-functions
                  'bongo-update-header-line-string)
        (add-hook 'bongo-player-times-changed-functions
                  'bongo-update-header-line-string))
    (remove-hook 'bongo-player-started-functions
                 'bongo-update-header-line-string)
    (remove-hook 'bongo-player-stopped-functions
                 'bongo-update-header-line-string)
    (remove-hook 'bongo-player-paused/resumed-functions
                 'bongo-update-header-line-string)
    (remove-hook 'bongo-player-times-changed-functions
                 'bongo-update-header-line-string))
  (when (interactive-p)
    (message "Bongo header line mode %s."
             (if bongo-header-line-mode
                 "enabled" "disabled")))
  bongo-header-line-mode)

(defgroup bongo-mode-line nil
  "Display of Bongo mode line indicator."
  :group 'bongo
  :group 'bongo-display)

(defcustom bongo-mode-line-indicator-mode t
  "Display a Bongo status indicator in the mode line.
See `bongo-mode-line-indicator-format'."
  :type 'boolean
  :initialize 'custom-initialize-default
  :set 'custom-set-minor-mode
  :group 'bongo-mode-line)

(defun bongo-hyphen-padded-mode-line-p ()
  "Return non-nil if the mode line is padded with hyphens.
That is, if `mode-line-format' ends with a string ending with \"%-\"."
  (and (listp mode-line-format)
       (let ((last (car (last mode-line-format))))
         (and (stringp last)
              (string-match "%-$" last)))))

(defun bongo-mode-line-pad-string ()
  "Return the string to use for padding in the mode line.
This is either \"-\" or \" \", depending on the return value of
the function `bongo-hyphen-padded-mode-line-p'."
  (if (bongo-hyphen-padded-mode-line-p) "-" " "))

(defcustom bongo-mode-line-indicator-format
  '((bongo-mode-line-pad-string)
    (when (bongo-hyphen-padded-mode-line-p) "[")
    (bongo-mode-line-previous-button)
    (bongo-mode-line-pause/resume-button)
    (bongo-mode-line-start/stop-button)
    (bongo-mode-line-next-button)
    (when (bongo-playing-p) " ")
    (when (bongo-playing-p)
      (cond ((and (bongo-elapsed-time) (bongo-total-time))
             (format "%d%%" (/ (* 100.0 (bongo-elapsed-time))
                               (bongo-total-time))))
            ((bongo-elapsed-time)
             (bongo-format-seconds (bongo-elapsed-time)))))
    (when (bongo-hyphen-padded-mode-line-p) "]")
    (bongo-mode-line-pad-string)
    (when (bongo-hyphen-padded-mode-line-p)
      (bongo-mode-line-pad-string)))
  "Template for the Bongo mode line indicator.
Value is a list of expressions, each evaluating to a string or nil.
The values of the expressions are concatenated."
  :type '(repeat
          (choice
           (const :tag "Padding" (bongo-mode-line-pad-string))
           (const :tag "Blank space" " ")
           string
           (const :tag "[Start] button"
                  (bongo-mode-line-start-button))
           (const :tag "[Stop] button"
                  (bongo-mode-line-stop-button))
           (const :tag "[Start] or [Stop] button"
                  (bongo-mode-line-start/stop-button))
           (const :tag "[Pause] or [Resume] button"
                  (bongo-mode-line-pause/resume-button))
           (const :tag "[Previous] button"
                  (bongo-mode-line-previous-button))
           (const :tag "[Next] button"
                  (bongo-mode-line-next-button))
           (const :tag "Elapsed time"
                  (when (bongo-playing-p)
                    (bongo-format-seconds (bongo-elapsed-time))))
           (const :tag "Remaining time"
                  (when (bongo-playing-p)
                    (bongo-format-seconds (bongo-remaining-time))))
           (const :tag "Total time"
                  (when (bongo-playing-p)
                    (bongo-format-seconds (bongo-total-time))))
           (const :tag "Elapsed time in percent of total time"
                  (when (bongo-playing-p)
                    (cond ((and (bongo-elapsed-time) (bongo-total-time))
                           (format "%d%%" (/ (* 100.0 (bongo-elapsed-time))
                                             (bongo-total-time))))
                          ((bongo-elapsed-time)
                           (bongo-format-seconds (bongo-elapsed-time))))))
           (const :tag "Elapsed and total time"
                  (when (bongo-playing-p)
                    (when (and (bongo-elapsed-time) (bongo-total-time))
                      (concat (bongo-format-seconds (bongo-elapsed-time)) "/"
                              (bongo-format-seconds (bongo-total-time))))))
           (const :tag "Padding if playing"
                  (when (bongo-playing-p)
                    (bongo-mode-line-pad-string)))
           (const :tag "Blank space if playing"
                  (when (bongo-playing-p) " "))
           (const :tag "Left bracket if mode line is hyphen-padded"
                  (when (bongo-hyphen-padded-mode-line-p) "["))
           (const :tag "Right bracket if mode line is hyphen-padded"
                  (when (bongo-hyphen-padded-mode-line-p) "]"))
           (const :tag "Padding if mode line is hyphen-padded"
                  (when (bongo-hyphen-padded-mode-line-p)
                    (bongo-mode-line-pad-string)))
           (const :tag "Padding if playing or mode line is hyphen-padded"
                  (when (or (bongo-playing-p)
                            (bongo-hyphen-padded-mode-line-p))
                    (bongo-mode-line-pad-string)))
           (sexp :tag "Value of arbitrary expression")))
  :group 'bongo-mode-line)

(defcustom bongo-mode-line-indicator-parent 'global-mode-string
  "List variable in which to put the Bongo mode line indicator.
Value is the name of a variable whose value is a list.
If nil, `bongo-mode-line-indicator-string' is not put anywhere."
  :type '(choice (const :tag "None" nil) variable)
  :group 'bongo-mode-line)

(defcustom bongo-mode-line-icon-color
  (face-foreground 'mode-line nil 'default)
  "Color of Bongo mode line icons."
  :type 'string
  :group 'bongo-mode-line)

(defcustom bongo-mode-line-playing-string "Playing"
  "Fallback string for the Bongo [Pause] button icon."
  :type 'string
  :group 'bongo-mode-line)

(defcustom bongo-mode-line-paused-string "Paused"
  "Fallback string for the Bongo [Resume] button icon."
  :type 'string
  :group 'bongo-mode-line)

(defvar bongo-mode-line-pause-icon-18
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *pause_18[] = {
/* width  height  number of colors  number of characters per pixel */
\" 18     18      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"..................\",
\"..................\",
\"..................\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"...####....####...\",
\"..................\",
\"..................\",
\"..................\"
};"))
  "Bongo [Pause] button icon (18 pixels tall).")

(defvar bongo-mode-line-pause-icon-11
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *pause_11[] = {
/* width  height  number of colors  number of characters per pixel */
\" 10     11      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"..........\",
\"..........\",
\"..##..##..\",
\"..##..##..\",
\"..##..##..\",
\"..##..##..\",
\"..##..##..\",
\"..##..##..\",
\"..##..##..\",
\"..........\",
\"..........\"};"))
  "Bongo [Pause] button icon (11 pixels tall).")

(defvar bongo-mode-line-resume-icon-18
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *resume_18[] = {
/* width  height  number of colors  number of characters per pixel */
\" 18     18      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"..................\",
\"..................\",
\"......##..........\",
\"......###.........\",
\"......####........\",
\"......#####.......\",
\"......######......\",
\"......#######.....\",
\"......########....\",
\"......########....\",
\"......#######.....\",
\"......######......\",
\"......#####.......\",
\"......####........\",
\"......###.........\",
\"......##..........\",
\"..................\",
\"..................\"
};"))
  "Bongo [Resume] button icon (18 pixels tall)")

(defvar bongo-mode-line-resume-icon-11
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *resume_11[] = {
/* width  height  number of colors  number of characters per pixel */
\" 10     11      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"..........\",
\"...#......\",
\"...##.....\",
\"...###....\",
\"...####...\",
\"...#####..\",
\"...####...\",
\"...###....\",
\"...##.....\",
\"...#......\",
\"..........\"
};"))
  "Bongo [Resume] button icon (11 pixels tall).")

(defvar bongo-mode-line-stop-icon-18
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *stop_18[] = {
/* width  height  number of colors  number of characters per pixel */
\" 18     18      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"..................\",
\"..................\",
\"..................\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"...############...\",
\"..................\",
\"..................\",
\"..................\"
};"))
  "Bongo [Stop] button icon (18 pixels tall).")

(defvar bongo-mode-line-stop-icon-11
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *stop_11[] = {
/* width  height  number of colors  number of characters per pixel */
\" 10     11      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"..........\",
\"..........\",
\"..######..\",
\"..######..\",
\"..######..\",
\"..######..\",
\"..######..\",
\"..######..\",
\"..######..\",
\"..........\",
\"..........\"};"))
  "Bongo [Stop] button icon (11 pixels tall).")

(defvar bongo-mode-line-previous-icon-18
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *previous_18[] = {
/* width  height  number of colors  number of characters per pixel */
\" 20     18      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"....................\",
\"....................\",
\"....................\",
\"....................\",
\"....................\",
\"......##......##....\",
\".....###.....###....\",
\"....####....####....\",
\"...#####...#####....\",
\"...#####...#####....\",
\"....####....####....\",
\".....###.....###....\",
\"......##......##....\",
\"....................\",
\"....................\",
\"....................\",
\"....................\",
\"....................\"
};"))
  "Bongo [Previous] button icon (18 pixels tall)")

(defvar bongo-mode-line-previous-icon-11
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *previous_11[] = {
/* width  height  number of colors  number of characters per pixel */
\" 11     11      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"...........\",
\"...........\",
\"...........\",
\"....#...#..\",
\"...##..##..\",
\"..###.###..\",
\"...##..##..\",
\"....#...#..\",
\"...........\",
\"...........\",
\"...........\"
};"))
  "Bongo [Previous] button icon (11 pixels tall).")

(defvar bongo-mode-line-next-icon-18
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *next_18[] = {
/* width  height  number of colors  number of characters per pixel */
\" 20     18      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"....................\",
\"....................\",
\"....................\",
\"....................\",
\"....................\",
\"....##......##......\",
\"....###.....###.....\",
\"....####....####....\",
\"....#####...#####...\",
\"....#####...#####...\",
\"....####....####....\",
\"....###.....###.....\",
\"....##......##......\",
\"....................\",
\"....................\",
\"....................\",
\"....................\",
\"....................\"
};"))
  "Bongo [Next] button icon (18 pixels tall)")

(defvar bongo-mode-line-next-icon-11
  '`(image :type xpm :ascent center :data ,(concat "/* XPM */
static char *next_11[] = {
/* width  height  number of colors  number of characters per pixel */
\" 11     11      2                 1\",
/* colors */
\"# c " bongo-mode-line-icon-color  "\",
\". c None\",
/* pixels */
\"...........\",
\"...........\",
\"...........\",
\"..#...#....\",
\"..##..##...\",
\"..###.###..\",
\"..##..##...\",
\"..#...#....\",
\"...........\",
\"...........\",
\"...........\"
};"))
  "Bongo [Next] button icon (11 pixels tall).")

(defvar bongo-mode-line-start-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (define-key map [mode-line mouse-1]
        (lambda (e)
          (interactive "e")
          (bongo-start))))))

(defvar bongo-mode-line-pause/resume-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (define-key map [mode-line mouse-1]
        (lambda (e)
          (interactive "e")
          (bongo-pause/resume))))))

(defvar bongo-mode-line-stop-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (define-key map [mode-line mouse-1]
        (lambda (e)
          (interactive "e")
          (bongo-stop))))))

(defvar bongo-mode-line-previous-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (define-key map [mode-line mouse-1]
        (lambda (e)
          (interactive "e")
          (bongo-play-previous))))))

(defvar bongo-mode-line-next-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (define-key map [mode-line mouse-1]
        (lambda (e)
          (interactive "e")
          (bongo-play-next))))))

(defun bongo-mode-line-icon-size ()
  "Return the size to use for mode line icons."
  (let ((font-size (aref (font-info (face-font 'mode-line)) 3)))
    (if (>= font-size 18) 18 11)))

(defun bongo-mode-line-start-button ()
  "Return the string to use as [Start] button in the mode line."
  (when (and window-system (not (bongo-playing-p)))
    (let ((icon-size (bongo-mode-line-icon-size)))
      (concat
       (propertize " " 'display '(space :width (1)))
       (propertize "[Start]"
                   'display (cond ((= icon-size 18)
                                   (eval bongo-mode-line-resume-icon-18))
                                  ((= icon-size 11)
                                   (eval bongo-mode-line-resume-icon-11)))
                   'help-echo (concat "mouse-1: start playback")
                   'local-map bongo-mode-line-start-map
                   'mouse-face 'highlight)
       (propertize " " 'display '(space :width (1)))))))

(defun bongo-mode-line-stop-button ()
  "Return the string to use as [Stop] button in the mode line."
  (when (and window-system (bongo-playing-p))
    (let ((icon-size (bongo-mode-line-icon-size)))
      (concat
       (propertize " " 'display '(space :width (1)))
       (propertize "[Stop]"
                   'display (cond ((= icon-size 18)
                                   (eval bongo-mode-line-stop-icon-18))
                                  ((= icon-size 11)
                                   (eval bongo-mode-line-stop-icon-11)))
                   'help-echo (concat "mouse-1: stop playback")
                   'local-map bongo-mode-line-stop-map
                   'mouse-face 'highlight)
       (propertize " " 'display '(space :width (1)))))))

(defun bongo-mode-line-start/stop-button ()
  "Return the string to use as [Start] or [Stop] button."
  (or (bongo-mode-line-start-button)
      (bongo-mode-line-stop-button)))

(defun bongo-mode-line-pause/resume-button ()
  "Return the string to use as [Pause] or [Resume] button."
  (when (and (bongo-playing-p) (bongo-pausing-supported-p))
    (if window-system
        (let ((icon-size (bongo-mode-line-icon-size)))
          (concat
           (propertize " " 'display '(space :width (1)))
           (propertize
            " "
            'display (if (bongo-paused-p)
                         (cond ((= icon-size 18)
                                (eval bongo-mode-line-resume-icon-18))
                               ((= icon-size 11)
                                (eval bongo-mode-line-resume-icon-11)))
                       (cond ((= icon-size 18)
                              (eval bongo-mode-line-pause-icon-18))
                             ((= icon-size 11)
                              (eval bongo-mode-line-pause-icon-11))))
            'help-echo (concat (if (bongo-paused-p)
                                   "mouse-1: resume "
                                 "mouse-1: pause ")
                               (bongo-format-infoset
                                (bongo-player-infoset bongo-player)))
            'local-map bongo-mode-line-pause/resume-map
            'mouse-face 'highlight)
           (propertize " " 'display '(space :width (1)))))
      (if (bongo-paused-p)
          bongo-mode-line-paused-string
        bongo-mode-line-playing-string))))

(defun bongo-mode-line-previous-button ()
  "Return the string to use as [Previous] button in the mode line."
  (when (and window-system (bongo-point-at-current-track-line))
    (let ((icon-size (bongo-mode-line-icon-size)))
      (concat
       (propertize " " 'display '(space :width (1)))
       (propertize "[Previous]"
                   'display (cond ((= icon-size 18)
                                   (eval bongo-mode-line-previous-icon-18))
                                  ((= icon-size 11)
                                   (eval bongo-mode-line-previous-icon-11)))
                   'help-echo
                   (let ((position (bongo-point-at-previous-track-line
                                    (bongo-point-at-current-track-line))))
                     (if position
                         (concat "mouse-1: play "
                                 (bongo-format-infoset
                                  (bongo-line-infoset position)))
                       "No previous track"))
                   'local-map bongo-mode-line-previous-map
                   'mouse-face 'highlight)
       (propertize " " 'display '(space :width (1)))))))

(defun bongo-mode-line-next-button ()
  "Return the string to use as [Next] button in the mode line."
  (when (and window-system (bongo-point-at-current-track-line))
    (let ((icon-size (bongo-mode-line-icon-size)))
      (concat
       (propertize " " 'display '(space :width (1)))
       (propertize "[Next]"
                   'display (cond ((= icon-size 18)
                                   (eval bongo-mode-line-next-icon-18))
                                  ((= icon-size 11)
                                   (eval bongo-mode-line-next-icon-11)))
                   'help-echo
                   (let ((position (bongo-point-at-next-track-line
                                    (bongo-point-at-current-track-line))))
                     (if position
                         (concat "mouse-1: play "
                                 (bongo-format-infoset
                                  (bongo-line-infoset position)))
                       "No next track"))
                   'local-map bongo-mode-line-next-map
                   'mouse-face 'highlight)
       (propertize " " 'display '(space :width (1)))))))

(defvar bongo-mode-line-indicator-string nil
  "Bongo mode line indicator string.
Value is derived from `bongo-mode-line-indicator-format'.
The name of this variable should go in, e.g., `global-mode-string'.")

;; This is needed for text properties to work in the mode line.
(put 'bongo-mode-line-indicator-string 'risky-local-variable t)

(defun bongo-update-mode-line-indicator-string (&rest dummy)
  "Update `bongo-mode-line-indicator-string'.
Otherwise, evalutate elements of `bongo-mode-line-indicator-format'.
Accept DUMMY arguments to ease hook usage."
  (when (bongo-buffer-p)
    (setq bongo-mode-line-indicator-string
          (apply 'concat
                 (mapcar 'eval bongo-mode-line-indicator-format)))))

(defun bongo-mode-line-indicator-mode (argument)
  "Toggle display of Bongo mode line indicator on or off.
With ARGUMENT equal to `toggle', or interactively
  with no prefix argument, toggle the mode.
With zero or negative ARGUMENT, turn the mode off.
With any other ARGUMENT, turn the mode on."
  ;; Use `toggle' rather than (if mode 0 1) so that using
  ;; `repeat-command' still does the toggling correctly.
  (interactive (list (or current-prefix-arg 'toggle)))
  (setq bongo-mode-line-indicator-mode
        (if (eq argument 'toggle)
            (not bongo-mode-line-indicator-mode)
          (> (prefix-numeric-value argument) 0)))
  (when (called-interactively-p)
    (customize-mark-as-set 'bongo-mode-line-indicator-mode))
  (when bongo-mode-line-indicator-parent
    (if (not bongo-mode-line-indicator-mode)
        (set bongo-mode-line-indicator-parent
             (remq 'bongo-mode-line-indicator-string
                   (symbol-value bongo-mode-line-indicator-parent)))
      (when (null (symbol-value bongo-mode-line-indicator-parent))
        (set bongo-mode-line-indicator-parent '("")))
      (add-to-list bongo-mode-line-indicator-parent
        'bongo-mode-line-indicator-string 'append)))
  (if bongo-mode-line-indicator-mode
      (progn
        (add-hook 'bongo-player-started-functions
                  'bongo-update-mode-line-indicator-string)
        (add-hook 'bongo-player-stopped-functions
                  'bongo-update-mode-line-indicator-string)
        (add-hook 'bongo-player-paused/resumed-functions
                  'bongo-update-mode-line-indicator-string)
        (add-hook 'bongo-player-times-changed-functions
                  'bongo-update-mode-line-indicator-string))
    (remove-hook 'bongo-player-started-functions
                 'bongo-update-mode-line-indicator-string)
    (remove-hook 'bongo-player-stopped-functions
                 'bongo-update-mode-line-indicator-string)
    (remove-hook 'bongo-player-paused/resumed-functions
                 'bongo-update-mode-line-indicator-string)
    (remove-hook 'bongo-player-times-changed-functions
                 'bongo-update-mode-line-indicator-string))
  (when (interactive-p)
    (message "Bongo mode line indicator mode %s."
             (if bongo-mode-line-indicator-mode
                 "enabled" "disabled")))
  bongo-mode-line-indicator-mode)

(defgroup bongo-infosets nil
  "Structured track information in Bongo."
  :group 'bongo)

(defcustom bongo-fields '(artist album track)
  "The fields that will be used to describe tracks and headers.

This list names the possible keys of a type of alist called an infoset.
The value of a field may be some arbitrarily complex data structure,
but the name of each field must be a simple symbol.

By default, each field consists of another alist:
 * the `artist' field consists of a single mandatory `name' subfield;
 * the `album' field consists of both a mandatory `title' subfield
   and an optional `year' subfield; and finally,
 * the `track' field consists of a mandatory `title' subfield
   and an optional `index' subfield.

Currently, this list needs to be completely ordered, starting with
the most general field and ending with the most specific field.
This restriction may be relaxed in the future to either allow partially
ordered field lists, or to abandon the hard-coded ordering completely.

The meaning and content of the fields are defined implicitly by the
functions that use and operate on fields and infosets (sets of fields).
Therefore, if you change this list, you probably also need to change
 (a) either `bongo-infoset-formatting-function' or
     `bongo-field-formatting-function',
 (b) `bongo-infoset-from-file-name-function', and
 (c) either `bongo-file-name-from-infoset-function' or
     `bongo-file-name-part-from-field-function'."
  :type '(repeat symbol)
  :group 'bongo-infosets)

(defcustom bongo-infoset-from-file-name-function
  'bongo-default-infoset-from-file-name
  "Function used to convert file names into infosets.
This function should be chosen so that the following
identity holds at all times:
   (equal (file-name-sans-extension
           (file-name-nondirectory FILE-NAME))
          (bongo-file-name-from-infoset
           (bongo-infoset-from-file-name FILE-NAME)))

Good functions are `bongo-default-infoset-from-file-name'
and `bongo-simple-infoset-from-file-name'.

See also `bongo-file-name-from-infoset-function'."
  :type 'function
  :options '(bongo-default-infoset-from-file-name
             bongo-simple-infoset-from-file-name)
  :group 'bongo-file-names
  :group 'bongo-infosets)

(defcustom bongo-file-name-from-infoset-function
  'bongo-default-file-name-from-infoset
  "Function used to represent an infoset as a file name.
This function should be chosen so that the following
identity holds at all times:
   (equal (file-name-sans-extension
           (file-name-nondirectory FILE-NAME))
          (bongo-file-name-from-infoset
           (bongo-infoset-from-file-name FILE-NAME)))

If the infoset cannot be represented as a file name, the
function should signal an error.  To satisfy the above
identity, this must not be the case for any infoset that
`bongo-infoset-from-file-name' can generate.

The default function cannot represent infosets that contain
general but not specific data.  For example, it cannot
represent ((artist (name \"Foo\"))), because a file name
containing only \"Foo\" would be interpreted as containing
only a track title.

See also `bongo-infoset-from-file-name-function'."
  :type 'function
  :group 'bongo-file-names
  :group 'bongo-infosets)

(defcustom bongo-file-name-part-from-field-function
  'bongo-default-file-name-part-from-field
  "Function used to represent an info field as part of a file name.
This is used by `bongo-default-file-name-from-infoset'."
  :type 'function
  :group 'bongo-file-names
  :group 'bongo-infosets)

(defcustom bongo-infoset-formatting-function
  'bongo-default-format-infoset
  "Function used to represent an infoset as a user-friendly string."
  :type 'function
  :group 'bongo-display
  :group 'bongo-infosets)

(defcustom bongo-field-formatting-function
  'bongo-default-format-field
  "Function used to represent an info field as a user-friendly string.
This is used by `bongo-default-format-infoset'."
  :type 'function
  :group 'bongo-display
  :group 'bongo-infosets)

(defgroup bongo-faces nil
  "Faces used by Bongo."
  :group 'bongo)

(defface bongo-comment
  '((t (:inherit font-lock-comment-face)))
  "Face used for comments in Bongo buffers."
  :group 'bongo-faces)

(defface bongo-warning
  '((t (:inherit font-lock-warning-face)))
  "Face used for warnings in Bongo buffers."
  :group 'bongo-faces)

(defface bongo-artist
  '((t (:inherit font-lock-keyword-face)))
  "Face used for Bongo artist names."
  :group 'bongo-faces)

(defface bongo-album '((t nil))
  "Face used for Bongo albums (year, title, and punctuation)."
  :group 'bongo-faces)

(defface bongo-album-title
  '((t (:inherit (font-lock-type-face bongo-album))))
  "Face used for Bongo album titles."
  :group 'bongo-faces)

(defface bongo-album-year
  '((t (:inherit bongo-album)))
  "Face used for Bongo album years."
  :group 'bongo-faces)

(defface bongo-track '((t nil))
  "Face used for Bongo tracks (index, title, and punctuation)."
  :group 'bongo-faces)

(defface bongo-track-title
  '((t (:inherit (font-lock-function-name-face bongo-track))))
  "Face used for Bongo track titles."
  :group 'bongo-faces)

(defface bongo-track-index
  '((t (:inherit bongo-track)))
  "Face used for Bongo track indices."
  :group 'bongo-faces)

(defface bongo-played-track
  '((t (:strike-through "#808080" :inherit bongo-track)))
  "Face used for already played Bongo tracks."
  :group 'bongo-faces)

(defface bongo-currently-playing-track
  '((t (:weight bold :inherit bongo-track)))
  "Face used for the currently playing Bongo track."
  :group 'bongo-faces)


;;;; Infoset- and field-related functions

(defun bongo-format-header (content collapsed-flag)
  "Decorate CONTENT so as to make it look like a header.
If COLLAPSED-FLAG is non-nil, assume the section is collapsed.

This function uses `bongo-expanded-header-format'
and `bongo-collapsed-header-format'."
  (format (if collapsed-flag
              bongo-collapsed-header-format
            bongo-expanded-header-format) content))

(defun bongo-format-infoset (infoset)
  "Represent INFOSET as a user-friendly string.
This function just calls `bongo-infoset-formatting-function'."
  (funcall bongo-infoset-formatting-function infoset))

(defun bongo-default-format-infoset (infoset)
  "Format INFOSET by calling `bongo-format-field' on each field.
Separate the obtained formatted field values by
  `bongo-field-separator'."
  (mapconcat 'bongo-format-field infoset bongo-field-separator))

(defun bongo-file-name-from-infoset (infoset)
  "Represent INFOSET as a file name, if possible.
If INFOSET cannot be represented as a file name, signal an error.
This function just calls `bongo-file-name-from-infoset-function'.
See the documentation for that variable for more information."
  (funcall bongo-file-name-from-infoset-function infoset))

(defun bongo-default-file-name-from-infoset (infoset)
  "Represent INFOSET as a file name, if possible.
This function calls `bongo-file-name-part-from-field' on
each field and separates the obtained field values using
`bongo-file-name-field-separator'."
  ;; Signal an error if the infoset cannot be represented.
  (mapconcat 'bongo-file-name-part-from-field infoset
             bongo-file-name-field-separator))

(defun bongo-join-fields (values)
  (mapconcat 'identity values bongo-field-separator))

(defun bongo-join-file-name-fields (values)
  (mapconcat 'identity values bongo-file-name-field-separator))

(defun bongo-format-field (field)
  (funcall bongo-field-formatting-function field))

(defun bongo-default-format-field (field)
  (require 'format-spec)
  (let ((type (car field))
        (data (cdr field)))
    (case type
     ((artist)
      (propertize (bongo-alist-get data 'name) 'face 'bongo-artist))
     ((album)
      (let ((title (bongo-alist-get data 'title))
            (year (bongo-alist-get data 'year)))
        (if (null year) (propertize title 'face 'bongo-album-title)
          (format-spec bongo-album-format
                       `((?t . ,(propertize
                                 title 'face 'bongo-album-title))
                         (?y . ,(propertize
                                 year 'face 'bongo-album-year)))))))
     ((track)
      (let ((title (bongo-alist-get data 'title))
            (index (bongo-alist-get data 'index)))
        (if (null index) (propertize title 'face 'bongo-track-title)
          (format-spec bongo-track-format
                       `((?t . ,(propertize
                                 title 'face 'bongo-track-title))
                         (?i . ,(propertize
                                 index 'face 'bongo-track-index))))))))))

(defun bongo-file-name-part-from-field (field)
  "Represent FIELD as part of a file name.
This is used by `bongo-default-file-name-from-infoset'."
  (funcall bongo-file-name-part-from-field-function field))

(defun bongo-default-file-name-part-from-field (field)
  (let ((type (car field))
        (data (cdr field)))
    (case type
     ((artist) data)
     ((album)
      (let ((title (bongo-alist-get data 'title))
            (year (bongo-alist-get data 'year)))
        (if (null year) title
          (bongo-join-file-name-fields (list year title)))))
     ((track)
      (let ((title (bongo-alist-get data 'title))
            (index (bongo-alist-get data 'index)))
        (if (null index) title
          (bongo-join-file-name-fields (list index title))))))))

(defun bongo-infoset-from-file-name (file-name)
  (funcall bongo-infoset-from-file-name-function file-name))

(defun bongo-uri-scheme (file-name)
  "Return the URI scheme of FILE-NAME, or nil if it has none."
  (when (string-match (eval-when-compile
                        (rx string-start
                            (submatch
                             (any "a-zA-Z")
                             (zero-or-more
                              (or (any "a-zA-Z0-9$_@.&!*\"'(),")
                                  (and "%" (repeat 2 hex-digit)))))
                            ":"))
                      file-name)
    (match-string 1 file-name)))

(defun bongo-uri-p (file-name)
  "Return non-nil if FILE-NAME is a URI."
  (not (null (bongo-uri-scheme file-name))))

(defun bongo-unescape-uri (uri)
  "Replace all occurences of `%HH' in URI by the character HH."
  (with-temp-buffer
    (insert uri)
    (goto-char (point-min))
    (while (re-search-forward
            (eval-when-compile
              (rx (and "%" (submatch (repeat 2 hex-digit)))))
            nil 'no-error)
      (replace-match (char-to-string
                      (string-to-number (match-string 1) 16))))
    (buffer-string)))

(defun bongo-default-infoset-from-file-name (file-name)
  (if (bongo-uri-p file-name)
      `((track (title . ,(bongo-unescape-uri file-name))))
    (let* ((base-name (file-name-sans-extension
                       (file-name-nondirectory file-name)))
           (values (split-string base-name bongo-file-name-field-separator)))
      (when (> (length values) 5)
        (let ((fifth-and-rest (nthcdr 4 values)))
          (setcar fifth-and-rest (bongo-join-fields fifth-and-rest))
          (setcdr fifth-and-rest nil)))
      (cond
       ((= 5 (length values))
        (if (string-match bongo-file-name-track-index-regexp (nth 3 values))
            `((artist (name . ,(nth 0 values)))
              (album (year . ,(nth 1 values))
                     (title . ,(nth 2 values)))
              (track (index . ,(nth 3 values))
                     (title . ,(nth 4 values))))
          `((artist (name . ,(nth 0 values)))
            (album (year . ,(nth 1 values))
                   (title . ,(nth 2 values)))
            (track (title . ,(bongo-join-fields (nthcdr 3 values)))))))
       ((and (= 4 (length values))
             (string-match bongo-file-name-track-index-regexp (nth 2 values)))
        `((artist (name . ,(nth 0 values)))
          (album (title . ,(nth 1 values)))
          (track (index . ,(nth 2 values))
                 (title . ,(nth 3 values)))))
       ((and (= 4 (length values))
             (string-match bongo-file-name-album-year-regexp (nth 1 values)))
        `((artist (name . ,(nth 0 values)))
          (album (year . ,(nth 1 values))
                 (title . ,(nth 2 values)))
          (track (title . ,(nth 3 values)))))
       ((= 4 (length values))
        `((artist (name . ,(nth 0 values)))
          (album (title . ,(nth 1 values)))
          (track (title . ,(bongo-join-fields (nthcdr 2 values))))))
       ((= 3 (length values))
        `((artist (name . ,(nth 0 values)))
          (album (title . ,(nth 1 values)))
          (track (title . ,(nth 2 values)))))
       ((= 2 (length values))
        `((artist (name . ,(nth 0 values)))
          (track (title . ,(nth 1 values)))))
       ((= 1 (length values))
        `((track (title . ,(nth 0 values)))))))))

(defun bongo-simple-infoset-from-file-name (file-name)
  `((track (title . ,(file-name-sans-extension
                      (file-name-nondirectory
                       (if (bongo-uri-p file-name)
                           (bongo-unescape-uri file-name)
                         file-name)))))))

(defun bongo-infoset-artist-name (infoset)
  (bongo-alist-get (bongo-alist-get infoset 'artist) 'name))
(defun bongo-infoset-album-year (infoset)
  (bongo-alist-get (bongo-alist-get infoset 'album) 'year))
(defun bongo-infoset-album-title (infoset)
  (bongo-alist-get (bongo-alist-get infoset 'album) 'title))
(defun bongo-infoset-track-index (infoset)
  (bongo-alist-get (bongo-alist-get infoset 'track) 'index))
(defun bongo-infoset-track-title (infoset)
  (bongo-alist-get (bongo-alist-get infoset 'track) 'title))


;;;; Basic point-manipulation routines

(defun bongo-goto-point (point)
  "Set point to POINT, if POINT is non-nil.
POINT may be a number, a marker or nil."
  (when point (goto-char point)))

(defun bongo-skip-invisible ()
  "Move point to the next visible character.
If point is already on a visible character, do nothing."
  (while (and (not (eobp)) (line-move-invisible-p (point)))
    (goto-char (next-char-property-change (point)))))

(defun bongo-point-at-bol (&optional point)
  "Return the first character position of the line at POINT.
If `line-move-ignore-invisible' is non-nil, ignore invisible text."
  (save-excursion
    (bongo-goto-point point)
    (if (not line-move-ignore-invisible)
        (point-at-bol)
      (move-beginning-of-line nil)
      (bongo-skip-invisible)
      (point))))

(defun bongo-point-at-eol (&optional point)
  "Return the last character position of the line at POINT.
If `line-move-ignore-invisible' is non-nil, ignore invisible text."
  (save-excursion
    (bongo-goto-point point)
    (if (not line-move-ignore-invisible)
        (point-at-eol)
      (move-end-of-line nil)
      (point))))

(defun bongo-first-line-p (&optional point)
  "Return non-nil if POINT is on the first line."
  (= (bongo-point-at-bol point) (point-min)))

(defun bongo-last-line-p (&optional point)
  "Return non-nil if POINT is on the last line.
An empty line at the end of the buffer doesn't count."
  (>= (1+ (bongo-point-at-eol point)) (point-max)))

(defun bongo-first-object-line-p (&optional point)
  "Return non-nil if POINT is on the first object line."
  (null (bongo-point-at-previous-object-line point)))

(defun bongo-last-object-line-p (&optional point)
  "Return non-nil if POINT is on the last object line."
  (null (bongo-point-at-next-object-line point)))

(defalias 'bongo-point-before-line 'bongo-point-at-bol
  "Return the first character position of the line at POINT.")

(defun bongo-point-after-line (&optional point)
  "Return the first character position after the line at POINT.
In the normal case, for lines that end with newlines, the point
after a line is the same as the point before the next line."
  (let ((eol (bongo-point-at-eol point)))
    (if (= eol (point-max)) eol (1+ eol))))

(defun bongo-point-at-bol-forward (&optional point)
  "Return the position of the first line beginning after or at POINT.
If POINT is at the beginning of a line, just return POINT.
Otherwise, return the first character position after the line at POINT."
  (when (null point)
    (setq point (point)))
  (if (= point (bongo-point-at-bol point))
      point
    (bongo-point-after-line point)))

(define-obsolete-function-alias 'bongo-point-snapped-forwards
  'bongo-point-at-bol-forward)

(defun bongo-point-before-previous-line (&optional point)
  "Return the first position of the line before the one at POINT.
If the line at POINT is the first line, return nil."
  (unless (bongo-first-line-p point)
    (bongo-point-at-bol (1- (bongo-point-at-bol point)))))

(defun bongo-point-before-next-line (&optional point)
  "Return the first position of the line after the one at POINT.
If the line at POINT is the last line, return nil."
  (unless (bongo-last-line-p point)
    (1+ (bongo-point-at-eol point))))

(defalias 'bongo-point-at-previous-line
  'bongo-point-before-previous-line)

(defalias 'bongo-point-at-next-line
  'bongo-point-before-next-line)

(defun bongo-point-before-previous-line-satisfying (predicate &optional point)
  "Return the position of the previous line satisfying PREDICATE.
If POINT is non-nil, the search starts before the line at POINT.
If POINT is nil, it starts before the current line.
If no matching line is found, return nil."
  (save-excursion
    (bongo-goto-point point)
    (when (not (bongo-first-line-p))
      (let (match)
        (while (and (not (bobp)) (not match))
          (let ((goal-column 0))
            (previous-line))
          (when (funcall predicate)
            (setq match t)))
        (when match
          (point))))))

(defalias 'bongo-point-at-previous-line-satisfying
  'bongo-point-before-previous-line-satisfying)

(defun bongo-point-before-next-line-satisfying (predicate &optional point)
  "Return the position of the next line satisfying PREDICATE.
If POINT is non-nil, the search starts after the line at POINT.
If POINT is nil, it starts after the current line.
If no matching line is found, return nil."
  (save-excursion
    (bongo-goto-point point)
    (when (not (bongo-last-line-p))
      (let (match)
        (while (and (not (eobp)) (not match))
          (let ((goal-column 0))
            (next-line))
          (when (funcall predicate)
            (setq match t)))
        (when match
          (point))))))

(defalias 'bongo-point-at-next-line-satisfying
  'bongo-point-before-next-line-satisfying)

(defun bongo-point-after-next-line-satisfying (predicate &optional point)
  "Return the position after the next line satisfying PREDICATE.
This function works like `bongo-point-before-next-line-satisfying'."
  (let ((before-next (bongo-point-before-next-line-satisfying
                      predicate point)))
    (when before-next
      (bongo-point-at-eol before-next))))

(defun bongo-point-before-previous-object-line (&optional point)
  "Return the character position of the previous object line.
If POINT is non-nil, start before that line; otherwise,
  start before the current line.
If no object line is found before the starting line, return nil."
  (bongo-point-before-previous-line-satisfying 'bongo-object-line-p point))

(defalias 'bongo-point-at-previous-object-line
  'bongo-point-before-previous-object-line)

(defun bongo-point-before-next-object-line (&optional point)
  "Return the character position of the next object line.
If POINT is non-nil, start after that line; otherwise,
  start after the current line.
If no object line is found after the starting line, return nil."
  (bongo-point-before-next-line-satisfying 'bongo-object-line-p point))

(defalias 'bongo-point-at-next-object-line
  'bongo-point-before-next-object-line)

(defun bongo-point-after-next-object-line (&optional point)
  "Return the character position after the next object line.
This function works like `bongo-point-before-next-object-line'."
  (bongo-point-after-next-line-satisfying 'bongo-object-line-p point))

(put 'bongo-no-previous-object
     'error-conditions
     '(error bongo-movement-error bongo-no-previous-object))
(put 'bongo-no-previous-object
     'error-message
     "No previous section or track")

(defun bongo-previous-object-line (&optional no-error)
  "Move point to the previous object line, if possible.
If NO-ERROR is non-nil, return non-nil if and only if point was moved.
If NO-ERROR is not given or nil, and there is no previous object line,
signal `bongo-no-previous-object-line'."
  (interactive "p")
  (let ((position (bongo-point-at-previous-object-line)))
    (if position
        (prog1 'point-moved
          (goto-char position))
      (unless no-error
        (signal 'bongo-no-previous-object nil)))))

(define-obsolete-function-alias 'bongo-backward-object-line
  'bongo-previous-object-line)

(put 'bongo-no-next-object
     'error-conditions
     '(error bongo-movement-error bongo-no-next-object))
(put 'bongo-no-next-object
     'error-message
     "No next section or track")

(defun bongo-next-object-line (&optional no-error)
  "Move point to the next object line, if possible.
If NO-ERROR is non-nil, return non-nil if and only if point was moved.
If NO-ERROR is not given or nil, and there is no next object line,
signal `bongo-no-next-object'."
  (interactive "p")
  (let ((position (bongo-point-at-next-object-line)))
    (if position
        (prog1 'point-moved
          (goto-char position))
      (unless no-error
        (signal 'bongo-no-next-object nil)))))

(define-obsolete-function-alias 'bongo-forward-object-line
  'bongo-next-object-line)

(defun bongo-snap-to-object-line (&optional no-error)
  "Move point to the next object line unless it is already on one.
If point was already on an object line, return `point-not-moved'.
If point was moved to the next object line, return `point-moved'.
If there is no next object line, signal `bongo-no-next-object'.
If NO-ERROR is non-nil, return nil instead of signalling an error."
  (interactive)
  (if (bongo-object-line-p)
      'point-not-moved
    (bongo-next-object-line no-error)))

(define-obsolete-function-alias 'bongo-maybe-forward-object-line
  'bongo-snap-to-object-line)

(put 'bongo-no-previous-header-line
     'error-conditions
     '(error bongo-movement-error bongo-no-previous-header-line))
(put 'bongo-no-previous-header-line
     'error-message
     "No previous header line")

(defun bongo-previous-header-line (&optional n)
  "Move N header lines backward.
With negative N, move forward instead."
  (interactive "p")
  (if (< n 0)
      (bongo-next-header-line (- n))
    (dotimes (dummy n)
      (let ((position (bongo-point-at-previous-line-satisfying
                       'bongo-header-line-p)))
        (if position
            (goto-char position)
          (signal 'bongo-no-previous-header-line nil))))))

(define-obsolete-function-alias 'bongo-backward-header-line
  'bongo-previous-header-line)

(put 'bongo-no-next-header-line
     'error-conditions
     '(error bongo-movement-error bongo-no-next-header-line))
(put 'bongo-no-next-header-line
     'error-message
     "No next header line")

(defun bongo-next-header-line (&optional n)
  "Move N header lines forward.
With negative N, move backward instead."
  (interactive "p")
  (if (< n 0)
      (bongo-previous-header-line (- n))
    (dotimes (dummy n)
      (let ((position (bongo-point-at-next-line-satisfying
                       'bongo-header-line-p)))
        (if position
            (goto-char position)
          (signal 'bongo-no-next-header-line nil))))))

(define-obsolete-function-alias 'bongo-forward-header-line
  'bongo-next-header-line)

(defun bongo-backward-expression (&optional n)
  "Move backward across one section, track, or stretch of text.
With prefix argument N, do it that many times.
With negative argument -N, move forward instead."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (if (< n 0)
      (bongo-forward-expression (- n))
    (catch 'done
      (dotimes (dummy n)
        (if (= (point) (point-min))
            (throw 'done nil)
          (goto-char (or (if (bongo-object-line-p)
                             (or (bongo-point-before-previous-object)
                                 (bongo-point-at-previous-object-line))
                           (bongo-point-after-line
                            (bongo-point-at-previous-object-line)))
                         (point-min))))))))

(define-obsolete-function-alias 'bongo-backward-section
  'bongo-backward-expression)

(defun bongo-forward-expression (&optional n)
  "Move forward across one section, track, or stretch of text.
With prefix argument N, do it that many times.
With negative argument -N, move backward instead.
This function is a suitable value for `forward-sexp-function'."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (if (< n 0)
      (bongo-backward-expression (- n))
    (catch 'done
      (dotimes (dummy n)
        (if (= (point) (point-max))
            (throw 'done nil)
          (goto-char (or (if (bongo-object-line-p)
                             (bongo-point-after-object)
                           (bongo-point-before-next-object-line))
                         (point-max))))))))

(define-obsolete-function-alias 'bongo-forward-section
  'bongo-forward-expression)

(defun bongo-previous-object (&optional n)
  "Move to the previous object (either section or track).
With prefix argument N, do it that many times.
With negative prefix argument -N, move forward instead."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (if (< n 0)
      (bongo-next-object (- n))
    (dotimes (dummy n)
      (goto-char (or (bongo-point-at-previous-object)
                     (signal 'bongo-no-previous-object-line nil))))))

(defun bongo-next-object (&optional n)
  "Move to the next object (either section or track).
With prefix argument N, do it that many times.
With negative prefix argument -N, move backward instead."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (if (< n 0)
      (bongo-previous-object (- n))
    (dotimes (dummy n)
      (goto-char (or (bongo-point-at-next-object)
                     (signal 'bongo-no-next-object nil))))))

(defun bongo-point-before-next-track-line (&optional point)
  "Return the character position of the next track line.
If POINT is non-nil, start after that line; otherwise,
  start after the current line.
If no track line is found after the starting line, return nil."
  (bongo-point-before-next-line-satisfying 'bongo-track-line-p point))

(defalias 'bongo-point-at-next-track-line
  'bongo-point-before-next-track-line)

(defun bongo-point-before-previous-track-line (&optional point)
  "Return the character position of the previous track line.
If POINT is non-nil, start before that line; otherwise,
  start before the current line.
If no track line is found before the starting line, return nil."
  (bongo-point-before-previous-line-satisfying 'bongo-track-line-p point))

(defalias 'bongo-point-at-previous-track-line
  'bongo-point-before-previous-track-line)

(defun bongo-point-after-object (&optional point)
  "Return the character position after the object at POINT.
By object is meant either section or track.
If there are no sections or tracks at POINT, return nil."
  (save-excursion
    (bongo-goto-point point)
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (when (bongo-snap-to-object-line 'no-error)
      (let ((indentation (bongo-line-indentation)))
        (let ((after-last nil))
          (bongo-ignore-movement-errors
            (while (progn
                     (setq after-last (bongo-point-after-line))
                     (bongo-next-object-line)
                     (> (bongo-line-indentation) indentation))))
          after-last)))))

(define-obsolete-function-alias 'bongo-point-after-section
  'bongo-point-after-object)

(defun bongo-point-at-next-object (&optional point)
  "Return the character position of the object after the one at POINT.
By object is meant either section or track.
If there are no sections or tracks after the one at POINT, return nil."
  (save-excursion
    (if (bongo-object-line-p point)
        (let ((indentation (bongo-line-indentation point)))
          (goto-char (bongo-point-after-object point))
          (bongo-snap-to-object-line)
          (if (= (bongo-line-indentation) indentation)
              (point)
            (signal 'bongo-no-next-object nil)))
      (bongo-goto-point point)
      (bongo-snap-to-object-line))))

(defun bongo-point-before-previous-object (&optional point)
  "Return the character position of the object previous to POINT.
By object is meant either section or track.
If there are no sections or tracks before POINT, return nil."
  (save-excursion
    (bongo-goto-point point)
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (let ((indentation (if (bongo-snap-to-object-line 'no-error)
                           (bongo-line-indentation)
                         0)))
      (bongo-ignore-movement-errors
        (while (progn
                 (bongo-previous-object-line)
                 (> (bongo-line-indentation) indentation)))
        (when (= (bongo-line-indentation) indentation)
          (bongo-point-before-line))))))

(define-obsolete-function-alias 'bongo-point-before-previous-section
  'bongo-point-before-previous-object)

(defalias 'bongo-point-at-previous-object
  'bongo-point-before-previous-object)

(defun bongo-point-at-first-track-line ()
  "Return the character position of the first track line, or nil."
  (save-excursion
    (goto-char (point-min))
    (if (bongo-track-line-p)
        (bongo-point-at-bol)
      (bongo-point-at-next-track-line))))

(defun bongo-point-at-last-track-line ()
  "Return the character position of the last track line, or nil."
  (save-excursion
    (goto-char (point-max))
    (if (bongo-track-line-p)
        (bongo-point-at-bol)
      (bongo-point-at-previous-track-line))))

(defun bongo-track-infoset (&optional point)
  "Return the infoset for the track at POINT.
You should use `bongo-line-infoset' most of the time."
  (unless (bongo-track-line-p point)
    (error "Point is not on a track line"))
  (bongo-infoset-from-file-name (bongo-line-file-name point)))

(defun bongo-header-infoset (&optional point)
  "Return the infoset for the header at POINT.
You should use `bongo-line-infoset' most of the time."
  (save-excursion
    (bongo-goto-point point)
    (unless (bongo-header-line-p)
      (error "Point is not on a header line"))
    (let* ((line-move-ignore-invisible nil)
           (fields (bongo-line-fields))
           (indentation (bongo-line-indentation)))
      (while (and (bongo-next-object-line 'no-error)
                  (> (bongo-line-indentation) indentation)
                  (not (bongo-track-line-p))))
      (when (and (> (bongo-line-indentation) indentation)
                 (bongo-track-line-p))
        (bongo-filter-alist fields (bongo-track-infoset))))))

(defun bongo-line-infoset (&optional point)
  "Return the infoset for the line at POINT.
For track lines, the infoset is obtained by passing the file name to
  `bongo-file-name-parsing-function'.
For header lines, it is derived from the `bongo-fields' text property
  and the infoset of the nearest following track line."
    (cond
     ((bongo-track-line-p point) (bongo-track-infoset point))
     ((bongo-header-line-p point) (bongo-header-infoset point))))

(defun bongo-line-internal-infoset (&optional point)
  "Return the internal infoset for the line at POINT.
The internal infoset contains values of the internal fields only."
  (bongo-filter-alist (bongo-line-internal-fields point)
                      (bongo-line-infoset point)))

(defun bongo-line-field-value (field &optional point)
  "Return the value of FIELD for the line at POINT."
  (assoc field (bongo-line-infoset point)))

(defun bongo-line-field-values (fields &optional point)
  "Return the values of FIELDS for the line at POINT."
  (bongo-filter-alist fields (bongo-line-infoset point)))

(defun bongo-line-fields (&optional point)
  "Return the names of the fields defined for the line at POINT."
  (if (bongo-header-line-p point)
      (bongo-line-get-property 'bongo-fields point)
    (mapcar 'car (bongo-line-infoset point))))

(defun bongo-line-external-fields (&optional point)
  "Return the names of the fields external to the line at POINT."
  (bongo-line-get-property 'bongo-external-fields point))

(defun bongo-line-set-external-fields (fields &optional point)
  "Set FIELDS to be external to the line at POINT.
FIELDS should be a list of field names."
  (save-excursion
    (bongo-goto-point point)
    (bongo-line-set-property 'bongo-external-fields fields)
    (if (bongo-empty-header-line-p)
        (bongo-delete-line)
      (bongo-redisplay-line))))

(defun bongo-line-internal-fields (&optional point)
  "Return the names of the fields internal to the line at POINT."
  (bongo-set-difference (bongo-line-fields point)
                        (bongo-line-external-fields point)))

(defun bongo-line-indentation (&optional point)
  "Return the number of external fields of the line at POINT."
  (length (bongo-line-external-fields point)))

(defun bongo-line-indented-p (&optional point)
  (> (bongo-line-indentation point) 0))

(defun bongo-line-external-fields-proposal (&optional point)
  "Return the external fields proposal of the line at POINT.
This proposal is a list of field names that subsequent lines can
externalize if their field values match those of this line.

For track lines, this is always the same as the external field names.
For header lines, the internal field names are also added."
  (cond ((bongo-track-line-p point)
         (bongo-line-external-fields point))
        ((bongo-header-line-p point)
         (append (bongo-line-external-fields point)
                 (bongo-line-internal-fields point)))))

(defun bongo-line-indentation-proposal (&optional point)
  "Return the number of external fields proposed by the line at POINT.
See `bongo-line-external-fields-proposal'."
  (cond ((bongo-track-line-p point)
         (bongo-line-indentation point))
        ((bongo-header-line-p point)
         (+ (length (bongo-line-external-fields point))
            (length (bongo-line-internal-fields point))))))

(defun bongo-line-proposed-external-fields (&optional point)
  "Return the external fields proposed to the line at POINT.
This is nil for the first line, and equal to the external field names
proposal of the previous object line for all other lines."
  (if (bongo-first-object-line-p point) nil
    (bongo-line-external-fields-proposal
     (bongo-point-at-previous-object-line point))))

(defun bongo-line-proposed-indentation (&optional point)
  "Return the number of external fields proposed to the line at POINT.
See `bongo-line-proposed-external-fields'."
  (if (bongo-first-object-line-p point) 0
    (bongo-line-indentation-proposal
     (bongo-point-at-previous-object-line point))))

;;; (defun bongo-line-relatively-outdented-p ()
;;;   (< (bongo-line-indentation) (bongo-line-proposed-indentation)))

(defun bongo-line-file-name (&optional point)
  "Return the `bongo-file-name' text property of the file at POINT.
This will be nil for header lines and non-nil for track lines."
  (bongo-line-get-property 'bongo-file-name point))

(defun bongo-track-line-p (&optional point)
  "Return non-nil if the line at POINT is a track line."
  (not (null (bongo-line-file-name point))))

(defun bongo-currently-playing-track-line-p (&optional point)
  "Return non-nil if the line at POINT is currently playing."
  (and (bongo-current-track-line-p point)
       (bongo-playing-p)))

(defun bongo-played-track-line-p (&optional point)
  "Return non-nil if the line at POINT is a played track line."
  (and (bongo-track-line-p point)
       (bongo-line-get-property 'bongo-played point)))

(defun bongo-track-lines-exist-p ()
  "Return non-nil if the buffer contains any track lines.
This function does not care about the visibility of the lines."
  (let (track-lines-exist)
    (let ((line-move-ignore-invisible nil))
      (save-excursion
        (goto-char (point-min))
        (while (and (not (eobp)) (not track-lines-exist))
          (when (bongo-track-line-p)
            (setq track-lines-exist t))
          (forward-line))))
    track-lines-exist))

(defun bongo-header-line-p (&optional point)
  "Return non-nil if the line at POINT is a header line."
  (bongo-line-get-property 'bongo-header point))

(defun bongo-object-line-p (&optional point)
  "Return non-nil if the line at POINT is an object line.
Object lines are either track lines or header lines."
  (or (bongo-track-line-p point) (bongo-header-line-p point)))

(defun bongo-empty-header-line-p (&optional point)
  "Return non-nil if the line at POINT is an empty header line.
Empty header lines have no internal fields and are not supposed ever
to exist for long enough to be visible to the user."
  (and (bongo-header-line-p point)
       (null (bongo-line-internal-fields point))))

(defun bongo-collapsed-header-line-p (&optional point)
  "Return non-nil if the line at POINT is a collapsed header line.
Collapsed header lines are header lines whose sections are collapsed."
  (and (bongo-header-line-p point)
       (bongo-line-get-property 'bongo-collapsed point)))

(defun bongo-empty-section-p (&optional point)
  "Return non-nil if the line at POINT is an empty section.
That is, the header line of a section that has no content."
  (and (bongo-header-line-p point)
       (or (bongo-last-object-line-p point)
           (not (> (bongo-line-indentation
                    (bongo-point-at-next-object-line point))
                   (bongo-line-indentation point))))))


;;;; General convenience routines

(defsubst bongo-xor (a b)
  "Return non-nil if exactly one of A and B is nil."
  (if a (not b) b))

(defun bongo-shortest (a b)
  "Return the shorter of the lists A and B."
  (if (<= (length a) (length b)) a b))

(defun bongo-longest (a b)
  "Return the longer of the lists A and B."
  (if (>= (length a) (length b)) a b))

(defun bongo-equally-long-p (a b)
  "Return non-nil if the lists A and B have equal length."
  (= (length a) (length b)))

(defun bongo-set-union (&rest sets)
  "Return the set-theoretic union of the items in SETS.
Comparisons are done with `eq'.  Order is *not* preserved."
  (let (result)
    (dolist (set sets result)
      (dolist (entry set)
        (unless (memq entry result)
          (push entry result))))))

(defun bongo-set-intersection (a b)
  "Return the items in A that are also in B.
Comparisons are done with `eq'.  Order is preserved."
  (let (result)
    (dolist (entry a (nreverse result))
      (when (memq entry b)
        (push entry result)))))

(defun bongo-set-exclusive-or (a b)
  "Return the items that appear in either A or B but not both.
Comparisons are done with `eq'.  Order is *not* preserved."
  (let (result)
    (dolist (set (list a b) result)
      (dolist (entry set)
        (when (bongo-xor (memq entry a) (memq entry b))
          (push entry result))))))

(defun bongo-set-difference (a b)
  "Return the items in A that are not also in B.
Comparisons are done with `eq'.  Order is preserved."
  (let (result)
    (dolist (entry a (nreverse result))
      (unless (memq entry b)
        (push entry result)))))

(defun bongo-set-equal-p (a b)
  "Return non-nil if A and B have equal elements.
Comparisons are done with `eq'.  Element order is not significant."
  (null (bongo-set-exclusive-or a b)))

(defun bongo-subset-p (a b)
  "Return non-nil if all elements in B are also in A.
Comparisons are done with `eq'.  Element order is not significant."
  (bongo-set-equal-p (bongo-set-union a b) a))

(defun bongo-alist-get (alist key)
  "Return the cdr of the element in ALIST whose car equals KEY.
If no such element exists, return nil."
  (cdr-safe (assoc key alist)))

(defun bongo-alist-put (alist key value)
  "Set the cdr of the element in ALIST whose car equals KEY to VALUE.
If no such element exists, add a new element to the start of ALIST.
This function destructively modifies ALIST and returns the new head.
If ALIST is a symbol, operate on the vaule of that symbol instead."
  (if (and (symbolp alist) (not (null alist)))
      (set alist (bongo-alist-put (symbol-value alist) key value))
    (let ((entry (assoc key alist)))
      (if entry (prog1 alist (setcdr entry value))
        (cons (cons key value) alist)))))

(defun bongo-filter-alist (keys alist)
  "Return a new list of each pair in ALIST whose car is in KEYS.
Key comparisons are done with `eq'.  Order is preserved."
  (let (result)
    (dolist (entry alist (nreverse result))
      (when (memq (car entry) keys)
        (push entry result)))))

(defun bongo-filter-plist (keys plist)
  "Return a new list of each property in PLIST whose name is in KEYS.
Key comparisons are done with `eq'.  Order is *not* preserved."
  (let (result)
    (while plist
      (when (memq (car plist) keys)
        (setq result `(,(car plist) ,(cadr plist) ,@result)))
      (setq plist (cddr plist)))
    result))

(defun bongo-region-active-p ()
  "Return non-nil if the region is active."
  (and transient-mark-mode mark-active))


;;;; Fallback implementations of `process-{get,put}'.

(defvar bongo-process-alist nil)

(defun bongo-process-plist (process)
  (bongo-alist-get bongo-process-alist process))

(defun bongo-process-set-plist (process plist)
  (bongo-alist-put 'bongo-process-alist process plist))

(defun bongo-process-get (process property)
  "Return the value of PROPERTY for PROCESS."
  (plist-get (bongo-process-plist process) property))

(defun bongo-process-put (process property value)
  "Change the value of PROPERTY for PROCESS to VALUE."
  (bongo-process-set-plist
   process (plist-put (bongo-process-plist process)
                      property value)))

(when (and (fboundp 'process-put) (fboundp 'process-get))
  (defalias 'bongo-process-get 'process-get)
  (defalias 'bongo-process-put 'process-put))


;;;; Line-oriented convenience routines

(defun bongo-ensure-final-newline ()
  "Make sure the last line in the current buffer ends with a newline.
Do nothing if the current buffer is empty."
  (or (= (point-min) (point-max))
      (= (char-before (point-max)) ?\n)
      (save-excursion
        (goto-char (point-max))
        (insert "\n"))))

(defun bongo-delete-line (&optional point)
  "Delete the line at POINT."
  (let ((inhibit-read-only t))
    (delete-region (bongo-point-before-line point)
                   (bongo-point-after-line point))))

(defun bongo-line-string (&optional point)
  "Return the contents of the line at POINT.
The contents includes the final newline, if any."
  (buffer-substring (bongo-point-before-line point)
                    (bongo-point-after-line point)))

(defun bongo-extract-line (&optional point)
  "Delete the line at POINT and return its content.
The content includes the final newline, if any."
  (prog1 (bongo-line-string point)
    (bongo-delete-line point)))

(defun bongo-clear-line (&optional point)
  "Remove all contents of the line at POINT."
  (let ((inhibit-read-only t))
    (bongo-ensure-final-newline)
    (save-excursion
      (bongo-goto-point point)
      ;; Avoid deleting the newline, because that would
      ;; cause the markers on this line to become mixed up
      ;; with those on the next line.
      (delete-region (point-at-bol) (point-at-eol))
      ;; Remove all text properties from the newline.
      (set-text-properties (point) (1+ (point)) nil))))

(defun bongo-region-line-count (beg end)
  "Return the number of lines between BEG and END.
If BEG and END are the same, return 0.
If they are distinct but on the same line, return 1."
  (save-excursion
    (goto-char beg)
    (let ((result 0))
      (while (< (point) end)
        (setq result (1+ result))
        (forward-line))
      result)))


;;;; Text properties

(defun bongo-line-get-property (name &optional point)
  "Return the value of the text property NAME on the line at POINT.
Actually only look at the terminating newline."
  (get-text-property (bongo-point-at-eol point) name))

(defvar bongo-line-semantic-properties
  (list 'bongo-file-name 'bongo-header 'bongo-collapsed
        'bongo-fields 'bongo-external-fields
        'bongo-player 'bongo-played)
  "The list of semantic text properties used in Bongo buffers.
When redisplaying lines, semantic text properties are preserved,
whereas all other text properties (e.g., `face') are discarded.")

(defun bongo-line-get-semantic-properties (&optional point)
  "Return the list of semantic text properties on the line at POINT.
Actually only look at the terminating newline.

The value of `bongo-line-semantic-properties' determines which
text properties are considered \"semantic\" by this function."
  (bongo-filter-plist bongo-line-semantic-properties
                      (text-properties-at (bongo-point-at-eol point))))

(defun bongo-line-set-property (name value &optional point)
  "Set the text property NAME to VALUE on the line at POINT.
The text property will only be set for the terminating newline."
  (let ((inhibit-read-only t)
        (position (bongo-point-at-eol point)))
    (bongo-ensure-final-newline)
    (put-text-property position (1+ position) name value)))

(defun bongo-line-set-properties (properties &optional point)
  "Set the text properties PROPERTIES on the line at POINT.
The text properties will only be set for the terminating newline."
  (let ((inhibit-read-only t)
        (position (bongo-point-at-eol point)))
    (bongo-ensure-final-newline)
    (add-text-properties position (1+ position) properties)))

(defun bongo-line-remove-property (name &optional point)
  "Remove the text property NAME from the line at POINT.
The text properties will only be removed from the terminating newline."
  (let ((inhibit-read-only t)
        (position (bongo-point-at-eol point)))
    (bongo-ensure-final-newline)
    (remove-text-properties position (1+ position) (list name nil))))

(defun bongo-keep-text-properties (beg end keys)
  "Keep only some properties in text from BEG to END."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((properties (text-properties-at (point)))
               (kept-properties (bongo-filter-plist keys properties))
               (next (or (next-property-change (point)) (point-max))))
          (set-text-properties (point) next kept-properties)
          (goto-char next))))))


;;;; Sectioning

(defun bongo-field-common-in-region-p (beg end field)
  "Return non-nil if FIELD is common between BEG and END.
FIELD should be the name of a field (i.e., a symbol).
A field is common in a region if all object lines inside
the region share the same value for the field."
  (save-excursion
    (let ((last-value nil)
          (result t))
      (goto-char beg)
      (bongo-ignore-movement-errors
        (bongo-snap-to-object-line)
        (when (< (point) end)
          (if (null (setq last-value (bongo-line-field-value field)))
              (setq result nil)
            (bongo-next-object-line)
            (while (and result (< (point) end))
              (if (equal last-value (bongo-line-field-value field))
                  (bongo-next-object-line)
                (setq result nil))))))
      result)))

;; XXX: This will not work properly unless the fields are
;;      strictly hierarchical.
(defun bongo-common-fields-in-region (beg end)
  "Return the names of all fields that are common between BEG and END.
See `bongo-field-common-in-region-p'."
  (let ((fields (reverse bongo-fields))
        (common-fields nil))
    (while fields
      (if (bongo-field-common-in-region-p beg end (car fields))
          (when (null common-fields)
            (setq common-fields fields))
        (setq common-fields nil))
      (setq fields (cdr fields)))
    common-fields))

(defun bongo-common-fields-at-point (&optional point)
  "Return the names of all fields that are common at POINT.
A field is common at POINT if it is common in the region around
the object at POINT and either the previous or the next object."
  (save-excursion
    (bongo-goto-point point)
    (unless (bongo-object-line-p)
      (error "Point is not on an object line"))
    (let ((before-previous (bongo-point-before-previous-object-line))
          (after-next (bongo-point-after-next-object-line)))
      (bongo-longest
       (when before-previous
         (bongo-common-fields-in-region before-previous
                                        (bongo-point-after-line)))
       (when after-next
         (bongo-common-fields-in-region (bongo-point-before-line)
                                        after-next))))))

;; XXX: This will not work properly unless the fields are
;;      strictly hierarchical.
(defun bongo-fields-external-in-region-p (beg end fields)
  "Return non-nil if FIELDS are external between BEG and END.
Return nil if there is a field in FIELDS that is not external for
at least one line in the region."
  (save-excursion
    (let ((result t))
      (goto-char beg)
      (while (and (< (point) end) result)
        (when (< (bongo-line-indentation) (length fields))
          (setq result nil))
        (forward-line))
      result)))

;;; (defun bongo-external-fields-in-region-equal-p (beg end)
;;;   "In Bongo, return the fields that are external in the region.
;;; The region delimiters BEG and END should be integers or markers.
;;;
;;; Only the fields that are external for all objects throughout
;;; the region are considered to be external ``in the region.''"
;;;   (save-excursion
;;;     (goto-char beg)
;;;     (let* ((equal t)
;;;            (fields (bongo-external-fields))
;;;            (values (bongo-get fields)))
;;;       (while (and (< (point) end) equal)
;;;         (unless (equal (bongo-get fields) values)
;;;           (setq equal nil))
;;;         (forward-line))
;;;       equal)))
;;;
;;; (defun bongo-external-fields-at-point-equal-to-previous-p (&optional point)
;;;   (if (bongo-first-line-p point)
;;;       (zerop (bongo-indentation-at-point point))
;;;     (bongo-external-fields-in-region-equal-p
;;;      (bongo-point-before-previous-line point)
;;;      (bongo-point-after-line point))))

(defun bongo-line-potential-external-fields (&optional point)
  "Return the fields of the line at POINT that could be external.
That is, return the names of the fields that are common between
  the line at POINT and the object line before that.
If the line at POINT is the first line, return nil."
  (unless (bongo-first-object-line-p point)
    (bongo-common-fields-in-region
     (bongo-point-before-previous-object-line point)
     (bongo-point-after-line point))))

(defun bongo-line-externalizable-fields (&optional point)
  "Return the externalizable fields of the line at POINT.
That is, return the names of all internal fields of the line at POINT
  that could be made external without controversy.
This function respects `bongo-insert-intermediate-headers',
  in order to implement the correct semantics."
  (if bongo-insert-intermediate-headers
      (bongo-set-difference (bongo-set-intersection
                             (bongo-line-proposed-external-fields point)
                             (bongo-line-potential-external-fields point))
                            (bongo-line-external-fields point))
    ;; We are looking for an already existing header line, above the
    ;; current line, such that the proposed external fields below the
    ;; existing header line is a subset of the potential external
    ;; fields of the current line.  If such a header line exists, then
    ;; the externalizable fields of the current line is equal to the
    ;; proposed external fields of the existing header line.
    (let ((potential (bongo-line-potential-external-fields point)))
      (bongo-ignore-movement-errors
        (save-excursion
          ;; We begin the search on the previous line.
          (bongo-previous-object-line)
          ;; If this is a header line, it might be the one we are
          ;; looking for.
          (or (and (bongo-header-line-p)
                   (let ((proposal (bongo-line-external-fields-proposal)))
                     (and (bongo-subset-p potential proposal) proposal)))
              ;; If not, continue the search by backing up to the parent
              ;; header line while there still is one.
              (let (fields)
                (while (and (null fields) (bongo-line-indented-p))
                  (bongo-backward-up-section)
                  (let ((proposal (bongo-line-external-fields-proposal)))
                    (when (bongo-subset-p potential proposal)
                      (setq fields proposal))))
                fields)))))))

(defun bongo-redundant-header-line-p (&optional point)
  "Return non-nil if the line at POINT is a redundant header.
Redundant headers are headers whose internal fields are all externalizable."
  (and (bongo-header-line-p point)
       (bongo-set-equal-p (bongo-line-externalizable-fields point)
                          (bongo-line-internal-fields point))))

(defun bongo-down-section (&optional n)
  "Move to the first object line in the section at point.
With N, repeat that many times.
If there are not enough sections at point, signal an error."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (while (> n 0)
    (bongo-snap-to-object-line)
    (if (bongo-header-line-p)
        (let ((indentation (bongo-line-indentation)))
          (unless (and (bongo-next-object-line 'no-error)
                       (> (bongo-line-indentation) indentation))
            (error "Empty section")))
      (error "No section here"))
    (setq n (- n 1))))

(defun bongo-backward-up-section (&optional n)
  "Move to the header line of this section.
With N, repeat that many times."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (while (> n 0)
    (let ((indentation (bongo-line-indentation)))
      (when (zerop indentation)
        (error "Already at the top level"))
      (while (progn (bongo-previous-object-line)
                    (>= (bongo-line-indentation) indentation))))
    (setq n (- n 1))))

(defun bongo-maybe-insert-intermediate-header ()
  "Make sure that the current line has a suitable header.
If the first outer header is too specific, split it in two."
  (when (bongo-line-indented-p)
    (let ((current (bongo-line-external-fields)))
      (save-excursion
        (bongo-backward-up-section)
        (let ((proposal (bongo-line-external-fields-proposal)))
          (unless (bongo-set-equal-p current proposal)
            (bongo-insert-header current)
            (bongo-externalize-fields)))))))

(defun bongo-externalize-fields ()
  "Externalize as many fields of the current line as possible.
This function may create a new section header, but only by splitting an
existing header into two (see `bongo-maybe-insert-intermediate-header')."
  (unless (zerop (bongo-line-proposed-indentation))
    (let ((fields (bongo-line-externalizable-fields)))
      (when (> (length fields) (bongo-line-indentation))
        (bongo-line-set-external-fields fields)
        (bongo-maybe-insert-intermediate-header)))))


;;;; Backends

(defun bongo-backend (backend-name)
  "Return the backend called BACKEND-NAME.
If BACKEND-NAME is not a symbol, just return it."
  (if (symbolp backend-name)
      (get backend-name 'bongo-backend)
    backend-name))

(defun bongo-backend-name (backend)
  "Return the name of BACKEND."
  (car backend))

(defun bongo-backend-pretty-name (backend)
  "Return BACKEND's pretty name."
  (or (bongo-backend-get backend 'pretty-name)
      (symbol-name (bongo-backend-name backend))))

(defun bongo-backend-get (backend property)
  "Return the value of BACKEND's PROPERTY."
  (bongo-alist-get (cdr (bongo-backend backend)) property))

(defun bongo-backend-put (backend property value)
  "Set BACKEND's PROPERTY to VALUE."
  (bongo-alist-put (cdr (bongo-backend backend)) property value))

(defun bongo-backend-constructor (backend)
  "Return BACKEND's constructor."
  (bongo-backend-get backend 'constructor))

(defun bongo-backend-program-name (backend)
  "Return BACKEND's program name."
  (let ((program-name (bongo-backend-get backend 'program-name)))
    (if (symbolp program-name)
        (symbol-value program-name)
      program-name)))

(defun bongo-backend-program-arguments (backend)
  "Return BACKEND's program argument list."
  (bongo-backend-get backend 'program-arguments))

(defun bongo-file-name-matches-p (file-name matcher)
  "Return non-nil if FILE-NAME matches MATCHER.
MATCHER is of the form (TYPE-MATCHER . VALUE-MATCHER),
where TYPE-MATCHER is either `local-file' or a string
of the form \"URI-SCHEME:\", or a list of such atoms.
The possible values of VALUE-MATCHER are listed below.

If it is t, return non-nil immediately.
If it is a string, treat it as a regular expression;
  return non-nil if FILE-NAME matches VALUE-MATCHER.
If it is a symbol, treat it as a function name;
  return non-nil if (VALUE-MATCHER FILE-NAME) returns non-nil.
If it is a list of strings, treat it as a set of file name extensions;
  return non-nil if the extension of FILE-NAME appears in VALUE-MATCHER.
Otherwise, signal an error."
  (let ((type-matcher (car matcher))
        (value-matcher (cdr matcher)))
    (when (let* ((uri-scheme (bongo-uri-scheme file-name))
                 (needed-type-matcher
                  (if uri-scheme
                      (concat uri-scheme ":")
                    'local-file)))
            (or (equal type-matcher needed-type-matcher)
                (and (listp type-matcher)
                     (member needed-type-matcher type-matcher))))
      (cond
       ((eq value-matcher t) t)
       ((stringp value-matcher) (string-match value-matcher file-name))
       ((symbolp value-matcher) (funcall value-matcher file-name))
       ((and (listp value-matcher) (stringp (car value-matcher)))
        (let ((actual-extension
               (downcase (or (file-name-extension file-name) ""))))
          (catch 'match
            (dolist (extension value-matcher nil)
              (when (string-equal extension actual-extension)
                (throw 'match t))))))
       (t (error "Bad file name matcher: %s" value-matcher))))))

(defun bongo-backend-matchers ()
  (append bongo-custom-backend-matchers
          (apply 'nconc
                 (mapcar (lambda (matcher)
                           (when (memq (car matcher) bongo-enabled-backends)
                             (list matcher)))
                         bongo-backend-matchers))))

(defun bongo-backend-for-file (file-name)
  "Return the name of the backend to use for playing FILE-NAME."
  (let ((backend-name nil))
    (let ((matchers (bongo-backend-matchers)))
      (while (and matchers (null backend-name))
        (if (bongo-file-name-matches-p file-name (cdar matchers))
            (setq backend-name (caar matchers))
          (setq matchers (cdr matchers)))))
    (unless (eq backend-name 'ignore)
      backend-name)))

(define-obsolete-function-alias 'bongo-best-backend-for-file
  'bongo-backend-for-file)


;;;; Last.fm

(define-minor-mode bongo-lastfm-mode
  "Toggle Bongo Last.fm mode in the current buffer.
In Bongo Last.fm mode, information about played tracks is automatically
sumbitted to Last.fm (using `lastfm-submit').

Interactively with no prefix argument, toggle the mode.
With zero or negative ARG, turn the mode off.
With any other ARG, turn the mode on.

You can use Bongo Global Last.fm mode (see `bongo-global-lastfm-mode')
to automatically enable Bongo Last.fm mode in Bongo playlist buffers."
  :lighter " Last.fm"
  (if (bongo-playlist-buffer-p)
      (when (bongo-playing-p)
        (if bongo-lastfm-mode
            (bongo-start-lastfm-timer bongo-player)
          (bongo-cancel-lastfm-timer bongo-player)))
      (let ((value bongo-lastfm-mode))
        (kill-local-variable 'bongo-lastfm-mode)
        (when (not (null value))
          (error (concat "Bongo Last.fm mode can only be enabled "
                         "in Bongo playlists"))))))

(defun bongo-turn-on-lastfm-mode-if-applicable ()
  (when (bongo-playlist-buffer-p)
    (bongo-lastfm-mode 1)))

(define-global-minor-mode bongo-global-lastfm-mode
  bongo-lastfm-mode bongo-turn-on-lastfm-mode-if-applicable
  :initialize 'custom-initialize-default
  :init-value (and (boundp 'lastfmsubmit-program-name)
                   lastfmsubmit-program-name
                   (not (null (executable-find lastfmsubmit-program-name))))
  :group 'bongo)

(defun bongo-lastfm-submit (infoset length)
  "Submit song information to Last.fm using `lastfm-submit'."
  (require 'lastfm-submit)
  (let ((artist-name (bongo-infoset-artist-name infoset))
        (track-title (bongo-infoset-track-title infoset))
        (formatted-infoset (bongo-format-infoset infoset)))
    (if (or (null length) (null artist-name) (null track-title))
        (error "Cannot submit to Last.fm due to missing %s: %s"
               (cond ((null artist-name) "artist name")
                     ((null track-title) "track title")
                     ((null length) "track length"))
               formatted-infoset)
      (lastfm-submit artist-name track-title
                     (number-to-string (round length))
                     (bongo-infoset-album-title infoset))
      (message "Submitted to Last.fm: %s" formatted-infoset))))

(defun bongo-lastfm-submit-player (player)
  "Submit PLAYER's song information to Last.fm.
See `bongo-lastfm-submit'."
  (bongo-lastfm-submit (bongo-infoset-from-file-name
                        (bongo-player-file-name player))
                       (bongo-player-total-time player)))

(defun bongo-lastfm-submit-current ()
  "Sumbit the currently playing track to Last.fm."
  (interactive)
  (with-bongo-playlist-buffer
    (if (bongo-playing-p)
        (bongo-lastfm-submit-player bongo-player)
      (error "No active player"))))

(defun bongo-cancel-lastfm-timer (player)
  (when (bongo-player-get player 'lastfm-timer)
    (cancel-timer (bongo-player-get player 'lastfm-timer))
    (bongo-player-put player 'lastfm-timer nil)))

(defun bongo-lastfm-tick (player)
  ;; The Audioscrobbler website says that each song should
  ;; be submitted ``when it is 50% or 240 seconds complete,
  ;; whichever comes first.''
  (when (or (>= (bongo-player-elapsed-time player)
                (/ (bongo-player-total-time player) 2.0))
            (>= (bongo-player-elapsed-time player) 240))
    (when (or (null (bongo-player-buffer player))
              (with-current-buffer (bongo-player-buffer player)
                bongo-lastfm-mode))
      (bongo-lastfm-submit-player player))
    (bongo-cancel-lastfm-timer player)))

(defun bongo-start-lastfm-timer (player)
  (when (and (bongo-player-elapsed-time player)
             (bongo-player-total-time player)
             ;; ``Songs with a duration of less than 30
             ;; seconds should not be submitted,'' says the
             ;; Audioscrobbler website.
             (>= (bongo-player-total-time player) 30))
    (bongo-player-put player 'lastfm-timer
      (run-with-timer 1 1 'bongo-lastfm-tick player))))


;;;; Players

(defvar bongo-player nil
  "The currently active player for this buffer, or nil.
This variable is only used in Bongo mode buffers.")
(make-variable-buffer-local 'bongo-player)

(defcustom bongo-player-started-hook '(bongo-show)
  "Normal hook run when a Bongo player is started.
This hook is only run for players started in Bongo buffers."
  :options '(bongo-show)
  :type 'hook
  :group 'bongo)

(defvar bongo-player-started-functions nil
  "Abnormal hook run when a player is started.")

(defun bongo-fringe-icon-size ()
  "Return the size to use for fringe icons."
  (if (null window-system)
      ;; On Multi-TTY Emacs, `window-system' is a frame-local
      ;; variable, so default to the smallest size.
      11
    (let ((font-size (aref (font-info (face-font 'fringe)) 3)))
      (if (>= font-size 18) 18 11))))

(defvar bongo-playing-track-marker nil
  "Marker pointing at the currently playing track, if any.
As soon as the track is paused or stopped, this marker is set to
point to nowhere, and another marker assumes its role instead.")
(make-variable-buffer-local 'bongo-playing-track-marker)
(put 'bongo-playing-track-marker 'overlay-arrow-bitmap
       (ecase (bongo-fringe-icon-size)
         (11 'bongo-playing-11)
         (18 'bongo-playing-18)))

(defvar bongo-paused-track-marker nil
  "Marker pointing at the currently paused track, if any.
As soon as the track is unpaused or stopped, this marker is set to
point to nowhere, and another marker assumes its role instead.")
(make-variable-buffer-local 'bongo-paused-track-marker)
(put 'bongo-paused-track-marker 'overlay-arrow-bitmap
       (ecase (bongo-fringe-icon-size)
         (11 'bongo-paused-11)
         (18 'bongo-paused-18)))

(defvar bongo-stopped-track-marker nil
  "Marker pointing at the last stopped track, if any.
As soon as another track starts playing, this marker is set to
point to nowhere.")
(make-variable-buffer-local 'bongo-stopped-track-marker)
(put 'bongo-stopped-track-marker 'overlay-arrow-bitmap 'filled-square)

(defun bongo-play-file (file-name &optional backend)
  "Start playing FILE-NAME using BACKEND and return the new player.
If BACKEND is omitted or nil, Bongo will try to find the best player
  backend for FILE-NAME (using `bongo-backend-for-file').
This function runs `bongo-player-started-functions'."
  (let* ((constructor
          (bongo-backend-constructor
           (or (and backend (bongo-backend backend))
               (bongo-backend-for-file file-name)
               (error "Don't know how to play `%s'" file-name))))
         (player (funcall constructor file-name))
         (process (bongo-player-process player)))
    (prog1 player
      (when (and bongo-player-process-priority
                 process (eq 'run (process-status process)))
        (bongo-renice (process-id process)
                      bongo-player-process-priority))
      (when bongo-lastfm-mode
        (bongo-player-put player 'lastfm-timer
          (run-with-timer 5 nil 'bongo-start-lastfm-timer player)))
      (run-hook-with-args 'bongo-player-started-functions player))))

(define-obsolete-function-alias 'bongo-start-player
  'bongo-play-file)
(define-obsolete-function-alias 'bongo-play
  'bongo-play-file)

(defcustom bongo-player-finished-hook nil
  "Normal hook run when a Bongo player in Bongo mode finishes.
This hook is only run for players started in Bongo buffers."
  :options '((lambda () (bongo-show) (sit-for 2)))
  :type 'hook
  :group 'bongo)

(defvar bongo-player-succeeded-functions nil
  "Abnormal hook run when a player exits normally.")
(defvar bongo-player-failed-functions nil
  "Abnormal hook run when a player exits abnormally.")
(defvar bongo-player-killed-functions nil
  "Abnormal hook run when a player recieves a fatal signal.")
(defvar bongo-player-finished-functions nil
  "Abnormal hook run when a player exits for whatever reason.")

(defun bongo-player-succeeded (player)
  "Run the hooks appropriate for when PLAYER has succeeded."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-succeeded-functions player)
    (bongo-player-finished player)))

(defun bongo-player-failed (player)
  "Run the hooks appropriate for when PLAYER has failed."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-failed-functions player)
    (bongo-player-finished player)))

(defun bongo-player-killed (player)
  "Run the hooks appropriate for when PLAYER was killed."
  (let ((process (bongo-player-process player)))
    (message "Process `%s' received fatal signal %s"
             (process-name process) (process-exit-status process)))
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-killed-functions player)
    (bongo-player-finished player)))

(defun bongo-perform-next-action ()
  "Perform the next Bongo action, if any.
The next action is specified by `bongo-next-action'."
  (interactive)
  (with-bongo-playlist-buffer
    (when bongo-next-action
      (let ((bongo-avoid-interrupting-playback nil))
        (funcall bongo-next-action)))))

(defun bongo-player-finished (player)
  "Run the hooks appropriate for when PLAYER has finished.
Then perform the next action according to `bongo-next-action'.
You should not call this function directly."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-finished-functions player)
    (when (bongo-buffer-p)
      (run-hooks 'bongo-player-finished-hook))
    (bongo-player-stopped player)
    (when (bongo-buffer-p)
      (bongo-perform-next-action))))

(defcustom bongo-player-explicitly-stopped-hook nil
  "Normal hook run after a Bongo player is explicitly stopped.
This hook is only run for players started in Bongo buffers."
  :type 'hook
  :group 'bongo)

(defvar bongo-player-explicitly-stopped-functions nil
  "Abnormal hook run after a Bongo player is explicitly stopped.")

(defun bongo-player-explicitly-stopped (player)
  "Run the hooks appropriate for when PLAYER was explicitly stopped."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-explicitly-stopped-functions player)
    (when (bongo-buffer-p)
      (run-hooks 'bongo-player-explicitly-stopped-hook))
    (bongo-player-stopped player)))

(defvar bongo-player-stopped-functions nil
  "Abnormal hook run when a player exits or is stopped.")

(defcustom bongo-player-stopped-hook nil
  "Normal hook run after a Bongo player exits or is stopped.
This hook is only run for players started in Bongo buffers."
  :type 'hook
  :group 'bongo)

(defun bongo-player-stopped (player)
  "Run the hooks appropriate for when PLAYER exited or was stopped."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (bongo-cancel-lastfm-timer player)
    (run-hook-with-args 'bongo-player-stopped-functions player)
    (when (bongo-buffer-p)
      (save-excursion
        (let ((position (bongo-point-at-current-track-line)))
          (when position
            (bongo-line-set-property 'bongo-played t position)
            (bongo-redisplay-line position)))
        (bongo-set-current-track-marker bongo-stopped-track-marker)
        (run-hooks 'bongo-player-stopped-hook)))
    (when (bufferp bongo-seek-buffer)
      (bongo-seek-redisplay))))

(defcustom bongo-player-paused/resumed-hook nil
  "Normal hook run after a Bongo player is paused or resumed.
This hook is only run for players started in Bongo buffers."
  :type 'hook
  :group 'bongo)

(defvar bongo-player-paused/resumed-functions nil
  "Abnormal hook run after a Bongo player is paused or resumed.")

(defun bongo-player-paused/resumed (player)
  "Run the hooks appropriate for when PLAYER has paused or resumed."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-paused/resumed-functions player)
    (when (bongo-buffer-p)
      (bongo-set-current-track-marker (if (bongo-paused-p)
                                          bongo-paused-track-marker
                                        bongo-playing-track-marker))
      (run-hooks 'bongo-player-paused/resumed-hook))))

(defcustom bongo-player-sought-hook nil
  "Normal hook run after a Bongo player seeks.
This hook is only run for players started in Bongo buffers."
  :type 'hook
  :group 'bongo)

(defvar bongo-player-sought-functions nil
  "Abnormal hook run after a Bongo player seeks.")

(defun bongo-player-sought (player method seconds)
  "Run the hooks appropriate for when PLAYER has sought.
METHOD is `:by' if the seek was relative or `:to' if it was absolute.
SECONDS is the number of seconds sought."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (bongo-cancel-lastfm-timer player)
    (bongo-player-put player 'elapsed-time
      (max 0 (case method
               (:to seconds)
               (:by (+ (bongo-player-elapsed-time player) seconds)))))
    (bongo-player-times-changed player)
    (bongo-player-put player 'last-seek-time (current-time))
    (run-hook-with-args 'bongo-player-sought-functions
                        player method seconds)
    (when (bongo-buffer-p)
      (run-hooks 'bongo-player-sought-hook))))

(defvar bongo-player-times-changed-functions nil
  "Abnormal hook run after one of the times of a Bongo player changes.
By ``one of the times'' is meant elapsed time or total time.")

(defun bongo-player-times-changed (player)
  "Run the hooks for when one of the times of PLAYER has changed."
  (save-current-buffer
    (when (buffer-live-p (bongo-player-buffer player))
      (set-buffer (bongo-player-buffer player)))
    (run-hook-with-args 'bongo-player-times-changed-functions player)
    (when (bufferp bongo-seek-buffer)
      (bongo-seek-redisplay))))

(defcustom bongo-player-process-priority nil
  "The desired scheduling priority of Bongo player processes.
If set to a non-nil value, `bongo-renice' will be used to alter
the scheduling priority after a player process is started."
  :type '(choice (const :tag "Default" nil)
                 (const :tag "Slightly higher (-5)" -5)
                 (const :tag "Much higher (-10)" -10)
                 (const :tag "Very much higher (-15)" -15)
                 integer)
  :group 'bongo)

(defcustom bongo-renice-command "sudo renice"
  "The shell command to use in place of the `renice' program.
It will get three arguments: the priority, \"-p\", and the PID."
  :type 'string
  :group 'bongo)

(defun bongo-renice (pid priority)
  "Alter the priority of PID (process ID) to PRIORITY.
The variable `bongo-renice-command' says what command to use."
  (call-process shell-file-name nil nil nil shell-command-switch
                (format "%s %d -p %d" bongo-renice-command
                        priority pid)))

(defun bongo-player-backend-name (player)
  "Return the name of PLAYER's backend."
  (car player))

(defun bongo-player-backend (player)
  "Return PLAYER's backend object."
  (bongo-backend (bongo-player-backend-name player)))

(defun bongo-player-get (player property)
  "Return the value of PLAYER's PROPERTY."
  (bongo-alist-get (cdr player) property))

(defun bongo-player-put (player property value)
  "Set PLAYER's PROPERTY to VALUE."
  (setcdr player (bongo-alist-put (cdr player) property value)))
(put 'bongo-player-put 'lisp-indent-function 2)

(defun bongo-player-push (player property element)
  "Push ELEMENT to the head of PLAYER's PROPERTY."
  (bongo-player-put player property
    (cons element (bongo-player-get player property))))
(put 'bongo-player-push 'lisp-indent-function 2)

(defun bongo-player-pop (player property)
  "Remove and return the head of PLAYER's PROPERTY."
  (let ((first-cell (bongo-player-get player property)))
    (prog1 (car first-cell)
      (bongo-player-put player property (cdr first-cell)))))

(defun bongo-player-shift (player property)
  "Remove and return the last element of PLAYER's PROPERTY."
  (let ((first-cell (bongo-player-get player property)))
    (if (null (cdr first-cell))
        (bongo-player-pop player property)
      (let ((penultimate-cell (last first-cell 2)))
        (prog1 (cadr penultimate-cell)
          (setcdr penultimate-cell nil))))))

(defun bongo-player-call (player method &rest arguments)
  "Call METHOD on PLAYER with extra ARGUMENTS."
  (apply (bongo-player-get player method) player arguments))

(defun bongo-player-call-with-default (player method default &rest arguments)
  "Call METHOD on PLAYER with extra ARGUMENTS.
If PLAYER has no property called METHOD, use DEFAULT instead."
  (apply (or (bongo-player-get player method) default) player arguments))

(defun bongo-player-process (player)
  "Return the process associated with PLAYER."
  (bongo-player-get player 'process))

(defun bongo-player-buffer (player)
  "Return the buffer associated with PLAYER."
  (bongo-player-get player 'buffer))

(defun bongo-player-file-name (player)
  "Return the name of the file played by PLAYER."
  (bongo-player-get player 'file-name))

(defun bongo-player-infoset (player)
  "Return the infoset for the file played by PLAYER."
  (bongo-infoset-from-file-name (bongo-player-file-name player)))

(defun bongo-player-show-infoset (player)
  "Display in the minibuffer what PLAYER is playing."
  (message (bongo-format-infoset (bongo-player-infoset player))))

(defun bongo-player-running-p (player)
  "Return non-nil if PLAYER's process is currently running."
  (eq 'run (process-status (bongo-player-process player))))

(defun bongo-player-explicitly-stopped-p (player)
  "Return non-nil if PLAYER was explicitly stopped."
  (bongo-player-get player 'explicitly-stopped))

(defun bongo-player-stop (player)
  "Tell PLAYER to stop playback completely.
When this function returns, PLAYER will no longer be usable."
  (bongo-player-put player 'explicitly-stopped t)
  (bongo-player-call-with-default
   player 'stop 'bongo-default-player-stop))

(defun bongo-player-interactive-p (player)
  "Return non-nil if PLAYER's process is interactive.
Interactive processes may support pausing and seeking."
  (bongo-player-call-with-default
   player 'interactive-p 'bongo-default-player-interactive-p))

(defun bongo-player-pausing-supported-p (player)
  "Return non-nil if PLAYER supports pausing."
  (bongo-player-call-with-default
   player 'pausing-supported-p 'bongo-default-player-pausing-supported-p))

(defun bongo-player-paused-p (player)
  "Return non-nil if PLAYER is paused."
  (bongo-player-call-with-default
   player 'paused-p 'bongo-default-player-paused-p))

(defun bongo-player-pause/resume (player)
  "Tell PLAYER to toggle its paused state.
If PLAYER does not support pausing, signal an error."
  (bongo-player-call-with-default
   player 'pause/resume 'bongo-default-player-pause/resume))

(defun bongo-player-seeking-supported-p (player)
  "Return non-nil if PLAYER supports seeking."
  (bongo-player-call-with-default
   player 'seeking-supported-p 'bongo-default-player-seeking-supported-p))

(defun bongo-player-seek-by (player n)
  "Tell PLAYER to seek to absolute position N.
If PLAYER does not support seeking, signal an error."
  (bongo-player-call-with-default
   player 'seek-by 'bongo-default-player-seek-by n))

(defun bongo-player-seek-to (player n)
  "Tell PLAYER to seek N units relative to the current position.
If PLAYER does not support seeking, signal an error."
  (bongo-player-call-with-default
   player 'seek-to 'bongo-default-player-seek-to n))

(defun bongo-player-elapsed-time (player)
  "Return the number of seconds PLAYER has played so far.
If the player backend cannot report this, return nil."
  (bongo-player-call-with-default
   player 'get-elapsed-time 'bongo-default-player-get-elapsed-time))

(defun bongo-player-total-time (player)
  "Return the total number of seconds PLAYER has and will use.
If the player backend cannot report this, return nil."
  (let ((value (bongo-player-call-with-default
                player 'get-total-time
                'bongo-default-player-get-total-time)))
    (and value (> value 0) value)))

(defun bongo-player-update-elapsed-time (player elapsed-time)
  "Set PLAYER's `elapsed-time' property unless PLAYER has just sought.
That is, set it unless PLAYER's last seek happened less than N seconds ago,
where N is the value of PLAYER's `time-update-delay-after-seek' property."
  (let ((delay (bongo-player-get player 'time-update-delay-after-seek)))
    (when (or (null delay) (zerop delay)
              (let ((time (bongo-player-get player 'last-seek-time)))
                (or (null time)
                    (time-less-p (seconds-to-time delay)
                                 (time-subtract (current-time) time)))))
      (bongo-player-put player 'elapsed-time elapsed-time))))

(defun bongo-player-update-total-time (player total-time)
  "Set PLAYER's `total-time' property to TOTAL-TIME."
  (bongo-player-put player 'total-time total-time))


;;;; Default implementations of player features

(defun bongo-default-player-stop (player)
  "Delete the process associated with PLAYER."
  (delete-process (bongo-player-process player))
  (bongo-player-explicitly-stopped player))

(defun bongo-default-player-interactive-p (player)
  "Return the value of PLAYER's `interactive' property."
  (bongo-player-get player 'interactive))

(defun bongo-default-player-pausing-supported-p (player)
  "Return the value of PLAYER's `pausing-supported' property."
  (bongo-player-get player 'pausing-supported))

(defun bongo-default-player-paused-p (player)
  "Return the value of PLAYER's `paused' property."
  (bongo-player-get player 'paused))

(defun bongo-default-player-pause/resume (player)
  "Signal an error explaining that PLAYER does not support pausing."
  (error "Pausing is not supported for %s"
         (bongo-player-backend-name player)))

(defun bongo-default-player-seeking-supported-p (player)
  "Return the value of PLAYER's `seeking-supported' property."
  (bongo-player-get player 'seeking-supported))

(defun bongo-default-player-seek-by (player n)
  "Signal an error explaining that PLAYER does not support seeking."
  (error "Relative seeking is not supported for %s"
         (bongo-player-backend-name player)))

(defun bongo-default-player-seek-to (player n)
  "Signal an error explaining that PLAYER does not support seeking."
  (error "Absolute seeking is not supported for %s"
         (bongo-player-backend-name player)))

(defun bongo-default-player-get-elapsed-time (player)
  "Return the value of PLAYER's `elapsed-time' property."
  (bongo-player-get player 'elapsed-time))

(defun bongo-default-player-get-total-time (player)
  "Return the value of PLAYER's `total-time' property."
  (bongo-player-get player 'total-time))

(defun bongo-default-player-process-sentinel (process string)
  "If PROCESS has exited or been killed, run the appropriate hooks."
  (let ((status (process-status process))
        (player (bongo-process-get process 'bongo-player)))
    (cond
     ((eq status 'exit)
      (if (zerop (process-exit-status process))
          (bongo-player-succeeded player)
        (message "Process `%s' exited abnormally with code %d"
                 (process-name process) (process-exit-status process))
        (bongo-player-failed player)))
     ((eq status 'signal)
      (unless (bongo-player-explicitly-stopped-p player)
        (bongo-player-killed player))))))


;;;; Backends

(defun bongo-evaluate-program-argument (argument)
  ;; Lists returned by this function will be destroyed by
  ;; the `nconc' in `bongo-evaluate-program-argument'.
  (cond
   ((stringp argument) (list argument))
   ((symbolp argument)
    (let ((value (symbol-value argument)))
      (if (listp value) (copy-sequence value) (list value))))
   ((listp argument)
    (let ((value (eval argument)))
      (if (listp value) (copy-sequence value) (list value))))
   (t (error "Invalid program argument specifier: `%s'" argument))))

(defun bongo-evaluate-program-arguments (arguments)
  (apply 'nconc (mapcar 'bongo-evaluate-program-argument arguments)))

(defun bongo-start-simple-player (backend file-name)
  ;; Do not change the name of the `file-name' parameter.
  ;; The simple constructor argument list relies on that
  ;; symbol being dynamically bound to the file name.
  (let* ((process-connection-type nil)
         (backend (bongo-backend backend))
         (backend-name (bongo-backend-name backend))
         (process (apply 'start-process
                         (format "bongo-%s" backend-name) nil
                         (bongo-backend-program-name backend)
                         (bongo-evaluate-program-arguments
                          (bongo-backend-program-arguments backend))))
         (player (list backend-name
                       (cons 'process process)
                       (cons 'file-name file-name)
                       (cons 'buffer (current-buffer)))))
    (prog1 player
      (set-process-sentinel process 'bongo-default-player-process-sentinel)
      (bongo-process-put process 'bongo-player player))))

(defmacro define-bongo-backend (name &rest options)
  (let* ((group-name
          (intern (format "bongo-%s" name)))
         (program-name-variable
          (or (eval (plist-get options :program-name-variable))
              (intern (format "bongo-%s-program-name" name))))
         (extra-program-arguments-variable
          (or (eval (plist-get options :extra-program-arguments-variable))
              (intern (format "bongo-%s-extra-arguments" name))))
         (pretty-name
          (or (eval (plist-get options :pretty-name))
              (symbol-name name)))
         (constructor
          (or (eval (plist-get options :constructor))
              (intern (format "bongo-start-%s-player" name))))
         (program-name
          (or (eval (plist-get options :program-name))
              (symbol-name name)))
         (program-arguments
          (or (eval (plist-get options :program-arguments))
              (list extra-program-arguments-variable 'file-name)))
         (extra-program-arguments
          (eval (plist-get options :extra-program-arguments)))
         (matchers
          (let ((options options)
                (result nil))
            (while options
              (when (eq (car options) :matcher)
                (setq result (cons (cadr options) result)))
              (setq options (cddr options)))
            (reverse result))))
    `(progn
       (defgroup ,group-name nil
         ,(format "The %s backend to Bongo." pretty-name)
         :prefix ,(format "bongo-%s-" name)
         :group 'bongo)

       ,@(when program-name-variable
           `((defcustom ,program-name-variable ',program-name
               ,(format "The name of the `%s' executable." program-name)
               :type 'string
               :group ',group-name)))

       ,@(when (and (not (null extra-program-arguments-variable))
                    (member extra-program-arguments-variable
                            program-arguments))
           `((defcustom ,extra-program-arguments-variable
               ',extra-program-arguments
               ,(format "Extra command-line arguments to pass to `%s'."
                        program-name)
               :type '(repeat (choice string variable sexp))
               :group ',group-name)))

       ,@(when (null (plist-get options :constructor))
           `((defun ,constructor (file-name)
               (bongo-start-simple-player ',name file-name))))

       ,@(mapcar (lambda (matcher)
                   `(add-to-list 'bongo-backend-matchers
                      (cons ',name ,matcher) t))
                 matchers)

       (put ',name 'bongo-backend
            '(,name (constructor . ,constructor)
                    (program-name . ,(or program-name-variable
                                         program-name))
                    (program-arguments . ,program-arguments)
                    (pretty-name . ,pretty-name)))
       (add-to-list 'bongo-backends ',name t)
       (bongo-evaluate-backend-defcustoms))))


;;;; The mpg123 backend

(define-bongo-backend mpg123
  :constructor 'bongo-start-mpg123-player
  ;; We define this variable manually so that we can get
  ;; some other customization variables to appear before it.
  :extra-program-arguments-variable nil
  :matcher '(local-file "mp3" "mp2"))

(defcustom bongo-mpg123-audio-driver nil
  "Audio driver (\"esd\", \"alsa\", etc.) to be used by mpg123.
This corresponds to the `-o' option of mpg123."
  :type '(choice (const :tag "System default" nil)
                 (const :tag "\
esd (the Enlightened Sound Daemon)" "esd")
                 (const :tag "\
alsa (the Advanced Linux Sound Architecture)" "alsa")
                 (const :tag "\
alsa09 (ALSA version 0.9)" "alsa")
                 (const :tag "\
arts (the analog real-time synthesiser)" "arts")
                 (const :tag "\
sun (the Sun audio system)" "sun")
                 (const :tag "\
oss (the Linux Open Sound System)" "oss")
                 (string :tag "Other audio driver"))
  :group 'bongo-mpg123)

(define-obsolete-variable-alias 'bongo-mpg123-device-type
  'bongo-mpg123-audio-driver)

(defcustom bongo-mpg123-audio-device nil
  "Audio device (e.g., for ALSA, \"1:0\") to be used by mpg123.
This corresponds to the `-a' option of mpg123."
  :type '(choice (const :tag "System default" nil) string)
  :group 'bongo-mpg123)

(define-obsolete-variable-alias 'bongo-mpg123-device
  'bongo-mpg123-audio-device)

(defcustom bongo-mpg123-interactive t
  "If non-nil, use the remote-control facility of mpg123.
Setting this to nil disables the pause and seek functionality."
  :type 'boolean
  :group 'bongo-mpg123)

(defun bongo-mpg123-is-mpg321-p ()
  "Return non-nil if the mpg123 program is actually mpg321."
  (string-match "^mpg321\\b" (shell-command-to-string
                              (concat bongo-mpg123-program-name
                                      " --version"))))

(defcustom bongo-mpg123-update-granularity
  (and (bongo-mpg123-is-mpg321-p) 30)
  "Number of frames to skip between each update from mpg321.
This corresponds to the mpg321-specific option --skip-printing-frames.
If your mpg123 does not support that option, set this variable to nil."
  :type '(choice (const :tag "None (lowest)" nil) integer)
  :group 'bongo-mpg123)

(defcustom bongo-mpg123-seek-increment 150
  "Step size (in frames) to use for relative seeking.
This variable is no longer used."
  :type 'integer
  :group 'bongo-mpg123)

(make-obsolete-variable 'bongo-mpg123-seek-increment
                        (concat "This variable is no longer used, "
                                "as the mpg123 backend now accepts "
                                "numbers of seconds to seek by."))

(defcustom bongo-mpg123-time-update-delay-after-seek 1
  "Number of seconds to delay time updates from mpg123 after seeking.
Such delays may prevent jerkiness in the visual seek interface."
  :type 'number
  :group 'bongo-mpg123)

(defcustom bongo-mpg123-extra-arguments nil
  "Extra command-line arguments to pass to `mpg123'.
These will come at the end or right before the file name, if any."
  :type '(repeat (choice string variable sexp))
  :group 'bongo-mpg123)

(define-obsolete-function-alias 'bongo-mpg123-player-interactive-p
  'bongo-player-interactive-p)

(define-obsolete-function-alias 'bongo-mpg123-player-paused-p
  'bongo-default-player-paused-p)

(defun bongo-mpg123-player-pause/resume (player)
  (if (bongo-player-interactive-p player)
      (progn
        (process-send-string (bongo-player-process player) "PAUSE\n")
        (bongo-player-put player 'paused
          (not (bongo-player-get player 'paused)))
        (bongo-player-paused/resumed player))
    (error (concat "This mpg123 process is not interactive "
                   "and so does not support pausing"))))

(defun bongo-seconds-to-mp3-frames (seconds)
  (round (* seconds 38.3)))

(defun bongo-mpg123-player-seek-to (player seconds)
  (if (bongo-player-interactive-p player)
      (progn
        (setq seconds (max seconds 0))
        (process-send-string
         (bongo-player-process player)
         (format "JUMP %d\n"
                 (bongo-seconds-to-mp3-frames seconds)))
        (bongo-player-sought player :to seconds))
    (error (concat "This mpg123 process is not interactive "
                   "and so does not support seeking"))))

(defun bongo-mpg123-player-seek-by (player seconds)
  (if (bongo-player-interactive-p player)
      (progn
        (process-send-string
         (bongo-player-process player)
         (format "JUMP %s%d\n" (if (< seconds 0) "-" "+")
                 (bongo-seconds-to-mp3-frames (abs seconds))))
        (bongo-player-sought player :by seconds))
    (error (concat "This mpg123 process is not interactive "
                   "and so does not support seeking"))))

;;; XXX: What happens if a record is split between two calls
;;;      to the process filter?
(defun bongo-mpg123-process-filter (process string)
  (condition-case condition
      (let ((player (bongo-process-get process 'bongo-player)))
        (with-temp-buffer
          (insert string)
          (goto-char (point-min))
          (while (not (eobp))
            (cond
             ((looking-at "^@P 0$")
              (bongo-player-succeeded player)
              (set-process-sentinel process nil)
              (delete-process process))
             ((looking-at "^@F .+ .+ \\(.+\\) \\(.+\\)$")
              (let* ((elapsed-time (string-to-number (match-string 1)))
                     (total-time (+ elapsed-time (string-to-number
                                                  (match-string 2)))))
                (bongo-player-update-elapsed-time player elapsed-time)
                (bongo-player-update-total-time player total-time)
                (bongo-player-times-changed player))))
            (forward-line))))
    ;; Getting errors in process filters is not fun, so stop.
    (error (bongo-stop)
           (signal (car condition) (cdr condition)))))

(defun bongo-start-mpg123-player (file-name)
  (let* ((process-connection-type nil)
         (arguments (append
                     (when bongo-mpg123-audio-driver
                       (list "-o" bongo-mpg123-audio-driver))
                     (when bongo-mpg123-audio-device
                       (list "-a" bongo-mpg123-audio-device))
                     (when bongo-mpg123-update-granularity
                       (list "--skip-printing-frames"
                             (number-to-string
                              bongo-mpg123-update-granularity)))
                     (bongo-evaluate-program-arguments
                      bongo-mpg123-extra-arguments)
                     (if bongo-mpg123-interactive
                         '("-R" "dummy") (list file-name))))
         (process (apply 'start-process "bongo-mpg123" nil
                         bongo-mpg123-program-name arguments))
         (player
          (list 'mpg123
                (cons 'process process)
                (cons 'file-name file-name)
                (cons 'buffer (current-buffer))
                (cons 'interactive bongo-mpg123-interactive)
                (cons 'pausing-supported bongo-mpg123-interactive)
                (cons 'seeking-supported bongo-mpg123-interactive)
                (cons 'time-update-delay-after-seek
                      bongo-mpg123-time-update-delay-after-seek)
                (cons 'paused nil)
                (cons 'pause/resume 'bongo-mpg123-player-pause/resume)
                (cons 'seek-by 'bongo-mpg123-player-seek-by)
                (cons 'seek-to 'bongo-mpg123-player-seek-to)
                (cons 'seek-unit 'seconds))))
    (prog1 player
      (set-process-sentinel process 'bongo-default-player-process-sentinel)
      (bongo-process-put process 'bongo-player player)
      (if (not bongo-mpg123-interactive)
          (set-process-filter process 'ignore)
        (set-process-filter process 'bongo-mpg123-process-filter)
        (process-send-string process (format "LOAD %s\n" file-name))))))


;;;; The mplayer backend

(define-bongo-backend mplayer
  :constructor 'bongo-start-mplayer-player
  ;; We define this variable manually so that we can get
  ;; some other customization variables to appear before it.
  :extra-program-arguments-variable nil
  ;; Play generic URLs and files if the file extension
  ;; matches that of some potentially supported format.
  :matcher '((local-file "file:" "http:" "ftp:")
             "ogg" "flac" "mp3" "mka" "wav" "wma"
             "mpg" "mpeg" "vob" "avi" "ogm" "mp4" "mkv"
             "mov" "asf" "wmv" "rm" "rmvb" "ts")
  ;; Play special media URIs regardless of the file name.
  :matcher '(("mms:" "mmst:" "rtp:" "rtsp:" "udp:" "unsv:"
              "dvd:" "vcd:" "tv:" "dvb:" "mf:" "cdda:" "cddb:"
              "cue:" "sdp:" "mpst:" "tivo:") . t)
  ;; Play all HTTP URLs (necessary for many streams).
  ;; XXX: This is not a good long-term solution.  (But it
  ;;      would be good to keep this matcher as a fallback
  ;;      if we could somehow declare that more specific
  ;;      matchers should be tried first.)
  :matcher '(("http:") . t))

(defun bongo-mplayer-available-drivers (type)
  (unless (memq type '(audio video))
    (error "Invalid device type"))
  (when (executable-find bongo-mplayer-program-name)
    (let ((result nil))
      (with-temp-buffer
        (call-process bongo-mplayer-program-name nil t nil
                      (ecase type
                        (audio "-ao")
                        (video "-vo"))
                      "help")
        (goto-char (point-min))
        (search-forward (concat "Available " (ecase type
                                               (audio "audio")
                                               (video "video"))
                                " output drivers:\n"))
        (while (looking-at
                (eval-when-compile
                  (rx line-start
                      (one-or-more space)
                      (submatch (one-or-more word))
                      (one-or-more space)
                      (submatch (zero-or-more not-newline))
                      line-end)))
          (setq result (cons (cons (match-string 1)
                                   (match-string 2))
                             result))
          (forward-line)))
      (reverse result))))

(defcustom bongo-mplayer-audio-driver nil
  "Audio driver to be used by mplayer.
This corresponds to the `-ao' option of mplayer."
  :type `(choice (const :tag "System default" nil)
                 ,@(mapcar (lambda (entry)
                             `(const :tag ,(concat (car entry)
                                                   " (" (cdr entry) ")")))
                           (bongo-mplayer-available-drivers 'audio))
                 (string :tag "Other audio driver"))
  :group 'bongo-mplayer)

(define-obsolete-variable-alias 'bongo-mplayer-audio-device
  'bongo-mplayer-audio-driver)

(defcustom bongo-mplayer-video-driver nil
  "Video driver to be used by mplayer.
This corresponds to the `-vo' option of mplayer."
  :type `(choice (const :tag "System default" nil)
                 ,@(mapcar (lambda (entry)
                             `(const :tag ,(concat (car entry)
                                                   " (" (cdr entry) ")")))
                           (bongo-mplayer-available-drivers 'video))
                 (string :tag "Other video driver"))
  :group 'bongo-mplayer)

(define-obsolete-variable-alias 'bongo-mplayer-video-device
  'bongo-mplayer-video-driver)

(defcustom bongo-mplayer-interactive t
  "If non-nil, use the slave mode of mplayer.
Setting this to nil disables the pause and seek functionality."
  :type 'boolean
  :group 'bongo-mplayer)

;; XXX: This variable is weird.
(defcustom bongo-mplayer-seek-increment 3.0
  "Step size (in seconds) to use for relative seeking.
This is used by `bongo-mplayer-seek-by'."
  :type 'float
  :group 'bongo-mplayer)

(defcustom bongo-mplayer-time-update-delay-after-seek 1
  "Number of seconds to delay time updates from mplayer after seeking.
Such delays may prevent jerkiness in the visual seek interface."
  :type 'number
  :group 'bongo-mplayer)

(defcustom bongo-mplayer-extra-arguments nil
  "Extra command-line arguments to pass to `mplayer'.
These will come at the end or right before the file name, if any."
  :type '(repeat (choice string variable sexp))
  :group 'bongo-mplayer)

(define-obsolete-function-alias 'bongo-mplayer-player-interactive-p
  'bongo-default-player-interactive-p)

(define-obsolete-function-alias 'bongo-mplayer-player-paused-p
  'bongo-default-player-paused-p)

(defun bongo-mplayer-player-pause/resume (player)
  (if (bongo-player-interactive-p player)
      (progn
        (process-send-string (bongo-player-process player) "pause\n")
        (bongo-player-put player 'paused
          (not (bongo-player-get player 'paused)))
        (bongo-player-paused/resumed player))
    (error "This mplayer process does not support pausing")))

(defun bongo-mplayer-player-seek-to (player seconds)
  (if (bongo-player-interactive-p player)
      (progn
        (setq seconds (max seconds 0))
        (process-send-string
         (bongo-player-process player)
         (format "seek %f 2\n" seconds))
        (bongo-player-sought player :to seconds))
    (error "This mplayer process does not support seeking")))

(defun bongo-mplayer-player-seek-by (player seconds)
  (if (bongo-player-interactive-p player)
      (progn
        ;; XXX: This is pretty, uh, weird.
        (setq seconds (* bongo-mplayer-seek-increment seconds))
        (process-send-string
         (bongo-player-process player)
         (format "seek %f 0\n" seconds))
        (bongo-player-sought player :by seconds))
    (error "This mplayer process does not support seeking")))

(defun bongo-mplayer-player-start-timer (player)
  (bongo-mplayer-player-stop-timer player)
  (let ((timer (run-with-timer 0 1 'bongo-mplayer-player-tick player)))
    (bongo-player-put player 'timer timer)))

(defun bongo-mplayer-player-stop-timer (player)
  (let ((timer (bongo-player-get player 'timer)))
    (when timer
      (cancel-timer timer)
      (bongo-player-put player 'timer nil))))

(defun bongo-mplayer-player-tick (player)
  (cond
   ((not (bongo-player-running-p player))
    (bongo-mplayer-player-stop-timer player))
   ((not (bongo-player-paused-p player))
    (let ((process (bongo-player-process player)))
      (process-send-string process "pausing_keep get_time_pos\n")
      (when (null (bongo-player-total-time player))
        (process-send-string process "pausing_keep get_time_length\n"))))))

;;; XXX: What happens if a record is split between two calls
;;;      to the process filter?
(defun bongo-mplayer-process-filter (process string)
  (condition-case condition
      (let ((player (bongo-process-get process 'bongo-player)))
        (with-temp-buffer
          (insert string)
          (goto-char (point-min))
          (while (not (eobp))
            (cond
             ((looking-at "^ANS_TIME_POSITION=\\(.+\\)$")
              (bongo-player-update-elapsed-time
               player (string-to-number (match-string 1)))
              (bongo-player-times-changed player))
             ((looking-at "^ANS_LENGTH=\\(.+\\)$")
              (bongo-player-update-total-time
               player (string-to-number (match-string 1)))
              (bongo-player-times-changed player)))
            (forward-line))))
    ;; Getting errors in process filters is not fun, so stop.
    (error (bongo-stop)
           (signal (car condition) (cdr condition)))))

(defun bongo-start-mplayer-player (file-name)
  (let* ((process-connection-type nil)
         (arguments (append
                     (when bongo-mplayer-audio-driver
                       (list "-ao" bongo-mplayer-audio-driver))
                     (when bongo-mplayer-video-driver
                       (list "-vo" bongo-mplayer-video-driver))
                     (when bongo-mplayer-interactive
                       (list "-quiet" "-slave"))
                     (bongo-evaluate-program-arguments
                      bongo-mplayer-extra-arguments)
                     (list file-name)))
         (process (apply 'start-process "bongo-mplayer" nil
                         bongo-mplayer-program-name arguments))
         (player
          (list 'mplayer
                (cons 'process process)
                (cons 'file-name file-name)
                (cons 'buffer (current-buffer))
                (cons 'interactive bongo-mplayer-interactive)
                (cons 'pausing-supported bongo-mplayer-interactive)
                (cons 'seeking-supported bongo-mplayer-interactive)
                (cons 'time-update-delay-after-seek
                      bongo-mplayer-time-update-delay-after-seek)
                (cons 'paused nil)
                (cons 'pause/resume 'bongo-mplayer-player-pause/resume)
                (cons 'seek-by 'bongo-mplayer-player-seek-by)
                (cons 'seek-to 'bongo-mplayer-player-seek-to)
                (cons 'seek-unit 'seconds))))
    (prog1 player
      (set-process-sentinel process 'bongo-default-player-process-sentinel)
      (bongo-process-put process 'bongo-player player)
      (when bongo-mplayer-interactive
        (set-process-filter process 'bongo-mplayer-process-filter)
        (bongo-mplayer-player-start-timer player)))))


;;;; The VLC backend

(define-bongo-backend vlc
  :pretty-name "VLC"
  :constructor 'bongo-start-vlc-player
  ;; We define this variable manually so that we can get
  ;; some other customization variables to appear before it.
  :extra-program-arguments-variable nil
  ;; Play generic URLs and files if the file extension
  ;; matches that of some potentially supported format.
  :matcher '((local-file "file:" "http:" "ftp:")
             "ogg" "flac" "mp3" "mka" "wav" "wma"
             "mpg" "mpeg" "vob" "avi" "ogm" "mp4" "mkv"
             "mov" "asf" "wmv" "rm" "rmvb" "ts")
  ;; Play special media URIs regardless of the file name.
  :matcher '(("mms:" "udp:" "dvd:" "vcd:" "cdda:") . t)
  ;; Play all HTTP URLs (necessary for many streams).
  ;; XXX: This is not a good long-term solution.  (But it
  ;;      would be good to keep this matcher as a fallback
  ;;      if we could somehow declare that more specific
  ;;      matchers should be tried first.)
  :matcher '(("http:") . t))

(defcustom bongo-vlc-interactive t
  "If non-nil, use the remote control interface of VLC.
Setting this to nil disables the pause and seek functionality."
  :type 'boolean
  :group 'bongo-vlc)

(defcustom bongo-vlc-initialization-period 0.2
  "Number of seconds to wait before querying VLC for time information.
If this number is too low, there might be a short period of time right
after VLC starts playing a track during which Bongo thinks that the total
track length is unknown."
  :type 'number
  :group 'bongo-vlc)

(defcustom bongo-vlc-time-update-delay-after-seek 1
  "Number of seconds to delay time updates from VLC after seeking.
Such delays may prevent jerkiness in the visual seek interface."
  :type 'number
  :group 'bongo-vlc)

(defcustom bongo-vlc-extra-arguments nil
  "Extra command-line arguments to pass to `vlc'.
These will come at the end or right before the file name, if any."
  :type '(repeat (choice string variable sexp))
  :group 'bongo-vlc)

(defun bongo-vlc-player-pause/resume (player)
  (if (bongo-player-interactive-p player)
      (process-send-string (bongo-player-process player) "pause\n")
    (error (concat "This VLC process is not interactive "
                   "and so does not support pausing"))))

(defun bongo-vlc-player-seek-to (player seconds)
  (if (bongo-player-interactive-p player)
      (progn
        (setq seconds (max seconds 0))
        (process-send-string
         (bongo-player-process player)
         (format "seek %f\n" seconds))
        (bongo-player-sought player :to seconds))
    (error (concat "This VLC process is not interactive "
                   "and so does not support seeking"))))

(defun bongo-vlc-player-seek-by (player seconds)
  (if (bongo-player-interactive-p player)
      (let ((elapsed-time (or (bongo-player-elapsed-time player) 0)))
        (bongo-vlc-player-seek-to player (+ elapsed-time seconds)))
    (error (concat "This VLC process is not interactive "
                   "and so does not support seeking"))))

(defun bongo-vlc-player-stop-timer (player)
  (let ((timer (bongo-player-get player 'timer)))
    (when timer
      (cancel-timer timer)
      (bongo-player-put player 'timer nil))))

(defun bongo-vlc-player-tick (player)
  (cond
   ((not (bongo-player-running-p player))
    (bongo-vlc-player-stop-timer player))
   ((and (not (bongo-player-paused-p player))
         (null (nthcdr 4 (bongo-player-get player 'pending-queries))))
    (let ((process (bongo-player-process player)))
      (process-send-string process "get_time\n")
      (bongo-player-push player 'pending-queries 'time)
      (when (null (bongo-player-total-time player))
        (process-send-string process "get_length\n")
        (bongo-player-push player 'pending-queries 'length))))))

(defun bongo-vlc-player-start-timer (player)
  (bongo-vlc-player-stop-timer player)
  (let ((timer (run-with-timer bongo-vlc-initialization-period
                               1 'bongo-vlc-player-tick player)))
    (bongo-player-put player 'timer timer)))

;;; XXX: What happens if a record is split between two calls
;;;      to the process filter?
(defun bongo-vlc-process-filter (process string)
  (condition-case condition
      (let ((player (bongo-process-get process 'bongo-player)))
        (with-temp-buffer
          (insert string)
          (goto-char (point-min))
          (while (not (eobp))
            (cond
             ((looking-at (eval-when-compile
                            (rx line-start
                                "status change:"
                                (zero-or-more (or whitespace "("))
                                (or "play" "stop") " state:"
                                (zero-or-more whitespace)
                                (submatch (one-or-more digit))
                                (zero-or-more (or whitespace ")"))
                                line-end)))
              (case (string-to-number (match-string 1))
                (0 (process-send-string process "quit\n"))
                (1 (bongo-player-put player 'paused nil)
                   (bongo-player-paused/resumed player)
                   (when (null (bongo-player-get player 'timer))
                     (bongo-vlc-player-start-timer player)))
                (2 (bongo-player-put player 'paused t)
                   (bongo-player-paused/resumed player))))
             ((looking-at (eval-when-compile
                            (rx line-start
                                (submatch (one-or-more digit))
                                (zero-or-more whitespace)
                                line-end)))
              (when (bongo-player-get player 'pending-queries)
                (let ((value (string-to-number (match-string 1))))
                  (ecase (bongo-player-shift player 'pending-queries)
                    (time
                     (bongo-player-update-elapsed-time player value)
                     (bongo-player-times-changed player))
                    (length
                     (bongo-player-update-total-time player value)
                     (bongo-player-times-changed player)))))))
            (forward-line))))
    ;; Getting errors in process filters is not fun, so stop.
    (error (bongo-stop)
           (signal (car condition) (cdr condition)))))

(defun bongo-start-vlc-player (file-name)
  (let* ((process-connection-type nil)
         (arguments (append
                     (when bongo-vlc-interactive
                       (list "-I" "rc" "--rc-fake-tty"))
                     (bongo-evaluate-program-arguments
                      bongo-vlc-extra-arguments)
                     (list file-name)))
         (process (apply 'start-process "bongo-vlc" nil
                         bongo-vlc-program-name arguments))
         (player
          (list 'vlc
                (cons 'process process)
                (cons 'file-name file-name)
                (cons 'buffer (current-buffer))
                (cons 'interactive bongo-vlc-interactive)
                (cons 'pausing-supported bongo-vlc-interactive)
                (cons 'seeking-supported bongo-vlc-interactive)
                (cons 'time-update-delay-after-seek
                      bongo-vlc-time-update-delay-after-seek)
                (cons 'paused nil)
                (cons 'pause/resume 'bongo-vlc-player-pause/resume)
                (cons 'seek-by 'bongo-vlc-player-seek-by)
                (cons 'seek-to 'bongo-vlc-player-seek-to)
                (cons 'seek-unit 'seconds))))
    (prog1 player
      (set-process-sentinel process 'bongo-default-player-process-sentinel)
      (bongo-process-put process 'bongo-player player)
      (when bongo-vlc-interactive
        (set-process-filter process 'bongo-vlc-process-filter)))))


;;;; Simple backends

(define-bongo-backend ogg123
  :matcher '(local-file "ogg" "flac"))

(define-bongo-backend speexdec
  :matcher '(local-file "spx"))

(define-bongo-backend timidity
  :pretty-name "TiMidity"
  :extra-program-arguments '("--quiet")
  :matcher '(local-file "mid" "midi" "mod" "rcp" "r36" "g18" "g36"))

(define-bongo-backend mikmod
  :pretty-name "MikMod"
  :extra-program-arguments '("-q" "-P" "1" "-X")
  :matcher `(local-file
             . ,(eval-when-compile
                  (rx "." (or "669" "amf" "dsm" "far" "gdm" "imf"
                              "it" "med" "mod" "mtm" "okt" "s3m"
                              "stm" "stx" "ult" "uni" "apun" "xm")
                      (optional
                       "." (or "zip" "lha" "lhz" "zoo" "gz" "bz2"
                               "tar" "tar.gz" "tar.bz2" "rar"))
                      string-end))))


;;;; DWIM commands

;; XXX: Should interpret numerical prefix argument as count.
(defun bongo-dwim (&optional prefix-argument)
  "In Bongo, do what the user means to the object at point.

If point is on a header, collapse or expand the section below.
If point is on a track, the action is contingent on the mode:
  In Bongo Playlist mode, call `bongo-play-line'.
  In Bongo Library mode, call `bongo-insert-enqueue-line' to
    insert the track into the playlist.  Then start playing
    that track, unless either `bongo-avoid-interrupting-playback'
    xor PREFIX-ARGUMENT is non-nil.

If point is neither on a track nor on a header, do nothing."
  (interactive "P")
  (cond
   ((and (bongo-track-line-p) (bongo-library-buffer-p))
    (let ((position (if (bongo-playing-p)
                        (bongo-insert-enqueue-line)
                      (bongo-append-enqueue-line))))
      (with-bongo-playlist-buffer
        (unless (and (bongo-playing-p)
                     (bongo-xor bongo-avoid-interrupting-playback
                                prefix-argument))
          (let ((bongo-avoid-interrupting-playback nil))
            (bongo-play-line position prefix-argument))))))
   ((and (bongo-track-line-p) (bongo-playlist-buffer-p))
    (bongo-play-line (point) prefix-argument))
   ((bongo-header-line-p)
    (bongo-toggle-collapsed))))

(defun bongo-mouse-dwim (event)
  "In Bongo, do what the user means to the object that was clicked on.
See `bongo-dwim'."
  (interactive "e")
  (let ((posn (event-end event)))
    (with-current-buffer (window-buffer (posn-window posn))
      (save-excursion
        (goto-char (posn-point posn))
        (bongo-dwim)))))


;;;; Controlling playback

(defun bongo-playing-p ()
  "Return non-nil if there is an active player for this buffer."
  (with-bongo-playlist-buffer
    (and (not (null bongo-player))
         (bongo-player-running-p bongo-player))))

(defun bongo-formatted-infoset ()
  "Return the formatted infoset of the active player, or nil."
  (with-bongo-playlist-buffer
    (when bongo-player
      (bongo-format-infoset
       (bongo-player-infoset bongo-player)))))

(defun bongo-pausing-supported-p ()
  "Return non-nil if the active player supports pausing."
  (with-bongo-playlist-buffer
    (and (bongo-playing-p)
         (bongo-player-pausing-supported-p bongo-player))))

(defun bongo-paused-p ()
  "Return non-nil if the active player is paused."
  (with-bongo-playlist-buffer
    (and (bongo-playing-p)
         (bongo-player-paused-p bongo-player))))

(defun bongo-seeking-supported-p ()
  "Return non-nil if the active player supports seeking."
  (with-bongo-playlist-buffer
    (and (bongo-playing-p)
         (bongo-player-seeking-supported-p bongo-player))))

(defun bongo-elapsed-time ()
  "Return the number of seconds played so far of the current track.
Return nil if the active player cannot report this."
  (with-bongo-playlist-buffer
    (when bongo-player
      (bongo-player-elapsed-time bongo-player))))

(defun bongo-remaining-time ()
  "Return the number of seconds remaining of the current track.
Return nil if the active player cannot report this."
  (let ((elapsed-time (bongo-elapsed-time))
        (total-time (bongo-total-time)))
    (when (and elapsed-time total-time)
      (- total-time elapsed-time))))

(defun bongo-total-time ()
  "Return the length of the currently playing track in seconds.
Return nil if the active player cannot report this."
  (with-bongo-playlist-buffer
    (when bongo-player
      (bongo-player-total-time bongo-player))))

(defvar bongo-current-track-marker nil
  "Marker pointing at the current track line, if any.
The current track line is the line of the currently playing track,
or that of the last played track if no track is currently playing.")
(make-variable-buffer-local 'bongo-current-track-marker)

(define-obsolete-variable-alias 'bongo-active-track-marker
  'bongo-current-track-marker)

(defun bongo-point-at-current-track-line ()
  (when bongo-current-track-marker
    (let ((position (marker-position bongo-current-track-marker)))
      (and (bongo-track-line-p position) position))))

(define-obsolete-function-alias 'bongo-active-track-position
  'bongo-point-at-current-track-line)
(define-obsolete-function-alias 'bongo-point-at-current-track
  'bongo-point-at-current-track-line)

(defun bongo-set-current-track-marker (marker)
  (unless (eq marker bongo-current-track-marker)
    (move-marker marker (bongo-point-at-current-track-line))
    (when bongo-current-track-marker
      (move-marker bongo-current-track-marker nil))
    (setq bongo-current-track-marker marker)))

(defun bongo-set-current-track-position (&optional position)
  (move-marker bongo-current-track-marker (or position (point))))

(define-obsolete-function-alias 'bongo-set-active-track
  'bongo-set-current-track-position)

(defun bongo-unset-current-track-position ()
  (move-marker bongo-current-track-marker nil))

(define-obsolete-function-alias 'bongo-unset-active-track
  'bongo-unset-current-track-position)

(defun bongo-current-track-line-p (&optional point)
  "Return non-nil if the line at POINT is the current track line."
  (and (not (null (bongo-point-at-current-track-line)))
       (>= (bongo-point-at-current-track-line)
           (bongo-point-before-line point))
       (< (bongo-point-at-current-track-line)
          (bongo-point-after-line point))))

(defun bongo-fringe-bitmap-from-strings (strings)
  (vconcat (mapcar (lambda (string)
                     (string-to-number
                      (replace-regexp-in-string
                       "#" "1" (replace-regexp-in-string "\\." "0" string)) 2))
                   strings)))

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'bongo-playing-11
    (bongo-fringe-bitmap-from-strings
     '("........"
       ".#......"
       ".##....."
       ".###...."
       ".####..."
       ".#####.."
       ".####..."
       ".###...."
       ".##....."
       ".#......"
       "........")))

  (define-fringe-bitmap 'bongo-playing-18
    (bongo-fringe-bitmap-from-strings
     '("................"
       "................"
       "....##.........."
       "....###........."
       "....####........"
       "....#####......."
       "....######......"
       "....#######....."
       "....########...."
       "....########...."
       "....#######....."
       "....######......"
       "....#####......."
       "....####........"
       "....###........."
       "....##.........."
       "................"
       "................"))
    18 16)

  (define-fringe-bitmap 'bongo-paused-11
    (bongo-fringe-bitmap-from-strings
     '("........"
       ".##..##."
       ".##..##."
       ".##..##."
       ".##..##."
       ".##..##."
       ".##..##."
       ".##..##."
       "........")))

  (define-fringe-bitmap 'bongo-paused-18
    (bongo-fringe-bitmap-from-strings
     '("................"
       "................"
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "..####....####.."
       "................"
       "................"))
    18 16))

(defvar bongo-queued-track-marker nil
  "Marker pointing at the queued track, if any.
This is used by `bongo-play-queued'.

The functions `bongo-set-queued-track-position' and
`bongo-unset-queued-track-position' can properly manipulate this
variable and its value.

If `bongo-avoid-interrupting-playback' is non-nil and a track is
currently being played, `bongo-play-line' sets the queued track.")
(make-variable-buffer-local 'bongo-queued-track-marker)

(defun bongo-point-at-queued-track-line ()
  "Return the position of `bongo-queued-track-marker', or nil."
  (and bongo-queued-track-marker
       (marker-position bongo-queued-track-marker)))

(define-obsolete-function-alias 'bongo-queued-track-position
  'bongo-point-at-queued-track-line)
(define-obsolete-function-alias 'bongo-point-at-queued-track
  'bongo-point-at-queued-track-line)

(defvar bongo-queued-track-arrow-marker nil
  "Overlay arrow marker following `bongo-queued-track-marker'.
See also `overlay-arrow-variable-list'.")
(make-variable-buffer-local 'bongo-queued-track-arrow-marker)

(defcustom bongo-queued-track-arrow-type 'blinking-arrow
  "Type of overlay arrow used to indicate the queued track.
If nil, don't indicate the queued track using an overlay arrow.
If `arrow', use a static arrow.  If `blinking-arrow', use a
blinking arrow (see `bongo-queued-track-arrow-blink-frequency').
See `bongo-queued-track-arrow-marker'."
  :type '(choice (const :tag "None" nil)
                 (const :tag "Arrow" arrow)
                 (const :tag "Blinking arrow" blinking-arrow))
  :group 'bongo-display)

(defcustom bongo-queued-track-arrow-blink-frequency 1
  "Frequency (in Hertz) with which to blink the queued track arrow.
See `bongo-queued-track-arrow-type'."
  :type 'number
  :group 'bongo-display)

(defvar bongo-queued-track-arrow-timer nil
  "The timer that updates the blinking queued track arrow, or nil.
See `bongo-queued-track-arrow-type'.")
(make-variable-buffer-local 'bongo-queued-track-arrow-timer)

(defun bongo-queued-track-line-p (&optional point)
  "Return non-nil if POINT is on the queued track.
See `bongo-queued-track-marker'."
  (save-excursion
    (bongo-goto-point point)
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (equal (bongo-point-at-queued-track-line)
           (bongo-point-at-bol))))

(defun bongo-unset-queued-track-position ()
  "Make `bongo-queued-track-marker' point nowhere.
In addition, set `bongo-next-action' to the value of
`bongo-stored-next-action' and set the latter to nil."
  (when bongo-queued-track-arrow-timer
    (cancel-timer bongo-queued-track-arrow-timer)
    (setq bongo-queued-track-arrow-timer nil))
  (when (bongo-point-at-queued-track-line)
    (setq bongo-next-action bongo-stored-next-action)
    (setq bongo-stored-next-action nil))
  (move-marker bongo-queued-track-marker nil)
  (move-marker bongo-queued-track-arrow-marker nil))

(define-obsolete-function-alias 'bongo-unset-queued-track
  'bongo-unset-queued-track-position)

(defun bongo-set-queued-track-position (&optional point)
  "Make `bongo-queued-track-marker' point to the track at POINT.
In addition, unless `bongo-next-action' is already set to
`bongo-play-queued', set `bongo-stored-next-action' to the value
of `bongo-next-action' and set the latter to `bongo-play-queued'."
  (interactive "d")
  (with-point-at-bongo-track point
    (move-marker bongo-queued-track-marker (point-at-bol point))
    (unless (eq bongo-next-action 'bongo-play-queued)
      (setq bongo-stored-next-action bongo-next-action
            bongo-next-action 'bongo-play-queued))
    (if (null bongo-queued-track-arrow-type)
        (message "Queued track: %s" (bongo-format-infoset
                                     (bongo-line-infoset point)))
      (move-marker bongo-queued-track-arrow-marker
                   bongo-queued-track-marker)
      (when (eq bongo-queued-track-arrow-type 'blinking-arrow)
        (when bongo-queued-track-arrow-timer
          (cancel-timer bongo-queued-track-arrow-timer))
        (setq bongo-queued-track-arrow-timer
              (run-at-time
               (/ 1.0 bongo-queued-track-arrow-blink-frequency)
               (/ 1.0 bongo-queued-track-arrow-blink-frequency)
               'bongo-blink-queued-track-arrow))))))

(define-obsolete-function-alias 'bongo-set-queued-track
  'bongo-set-queued-track-position)

(defun bongo-play-line (&optional point toggle-interrupt)
  "Start playing the track on the line at POINT.
If `bongo-avoid-interrupting-playback' is non-nil and a track is
  currently being played, call `bongo-set-queued-track' instead.
If TOGGLE-INTERRUPT (prefix argument if interactive) is non-nil,
  act as if `bongo-avoid-interrupting-playback' were reversed.
If there is no track on the line at POINT, signal an error."
  (interactive "d\nP")
  (unless (bongo-playlist-buffer-p)
    (error "Not a Bongo playlist buffer"))
  (with-point-at-bongo-track point
    (if (and (bongo-playing-p)
             (bongo-xor bongo-avoid-interrupting-playback
                        toggle-interrupt))
        ;; Something is being played and we should not
        ;; interrupt it.
        (if (bongo-queued-track-line-p)
            (bongo-unset-queued-track-position)
          (bongo-set-queued-track-position))
      ;; Nothing is being played or we should interrupt it.
      (when bongo-player
        (bongo-player-stop bongo-player))
      (bongo-set-current-track-position)
      (let ((player (bongo-play-file (bongo-line-file-name))))
        (setq bongo-player player)
        (bongo-line-set-property 'bongo-player player)
        (bongo-set-current-track-marker bongo-playing-track-marker)
        (run-hooks 'bongo-player-started-hook)
        (bongo-redisplay-line)))))

(defun bongo-blink-queued-track-arrow ()
  "Blink the overlay arrow indicating the queued track.
See `bongo-queued-track-arrow-marker'."
  (if (marker-position bongo-queued-track-arrow-marker)
      (move-marker bongo-queued-track-arrow-marker nil)
    (move-marker bongo-queued-track-arrow-marker
                 bongo-queued-track-marker)))

(defun bongo-play-queued ()
  "Play the track at `bongo-queued-track-marker'.
Then call `bongo-unset-queued-track'."
  (bongo-play-line (or (bongo-point-at-queued-track-line)
                       (error "No queued track")))
  (bongo-unset-queued-track-position))

(defun bongo-replay-current (&optional toggle-interrupt)
  "Play the current track in the nearest playlist from the start.
If `bongo-avoid-interrupting-playback' is non-nil,
  just set `bongo-next-action' to `bongo-replay-current'.
If TOGGLE-INTERRUPT (prefix argument if interactive) is non-nil,
  act as if `bongo-avoid-interrupting-playback' were reversed."
  (interactive "P")
  (with-bongo-playlist-buffer
    (if (not (bongo-xor bongo-avoid-interrupting-playback
                        toggle-interrupt))
        ;; We should interrupt playback, so play the current
        ;; track from the beginning.
        (let ((position (bongo-point-at-current-track-line))
              (bongo-avoid-interrupting-playback nil))
          (if position
              (bongo-play-line position)
            (error "No current track")))
      ;; We should not interrupt playback.
      (if (eq bongo-next-action 'bongo-replay-current)
          (message (concat "Switched to repeating playback "
                           "(prefix argument forces)."))
        (setq bongo-next-action 'bongo-replay-current)
        (message "Switched to repeating playback.")))))

(defun bongo-play-next (&optional n)
  "Start playing the next track in the nearest Bongo playlist buffer.
If there is no next track to play, signal an error.
With prefix argument N, skip that many tracks."
  (interactive "p")
  (with-bongo-playlist-buffer
    (let ((line-move-ignore-invisible nil)
          (position (bongo-point-at-current-track-line))
          (bongo-avoid-interrupting-playback nil))
      (when (null position)
        (error "No current track"))
      (dotimes (dummy (or n 1))
        (setq position (bongo-point-at-next-track-line position))
        (when (null position)
          (error "No next track")))
      (bongo-play-line position))))

(defun bongo-play-next-or-stop (&optional n)
  "Maybe start playing the next track in the nearest playlist buffer.
If there is no next track to play, stop playback.
With prefix argument N, skip that many tracks."
  (interactive "p")
  (when (null n)
    (setq n 1))
  (with-bongo-playlist-buffer
    (let ((line-move-ignore-invisible nil)
          (position (bongo-point-at-current-track-line))
          (bongo-avoid-interrupting-playback nil))
      (when (null position)
        (error "No current track"))
      (while (and position (> n 0))
        (setq position (bongo-point-at-next-track-line position))
        (setq n (- n 1)))
      (if position
          (bongo-play-line position)
        (bongo-stop)))))

(defun bongo-play-previous (&optional n)
  "Start playing the previous track in the nearest playlist buffer.
If there is no previous track to play, signal an error.
With prefix argument N, skip that many tracks."
  (interactive "p")
  (with-bongo-playlist-buffer
    (let ((line-move-ignore-invisible nil)
          (position (bongo-point-at-current-track-line))
          (bongo-avoid-interrupting-playback nil))
      (when (null position)
        (error "No current track"))
      (dotimes (dummy (or n 1))
        (setq position (bongo-point-at-previous-track-line position))
        (when (null position)
          (error "No previous track")))
      (bongo-play-line position))))

(defun bongo-play-random (&optional toggle-interrupt)
  "Start playing a random track in the nearest Bongo playlist buffer.
If `bongo-avoid-interrupting-playback' is non-nil,
  just set `bongo-next-action' to `bongo-play-random'.
If TOGGLE-INTERRUPT (prefix argument if interactive) is non-nil,
  act as if `bongo-avoid-interrupting-playback' were reversed."
  (interactive "P")
  (with-bongo-playlist-buffer
    (if (not (bongo-xor bongo-avoid-interrupting-playback
                        toggle-interrupt))
        ;; We should interrupt playback, so start playing a
        ;; random track immediately.
        (let ((line-move-ignore-invisible nil)
              (bongo-avoid-interrupting-playback nil))
          (unless (bongo-track-lines-exist-p)
            (error "Buffer contains no tracks"))
          (save-excursion
            (goto-char (1+ (random (point-max))))
            (bongo-play-line)))
      ;; We should not interrupt playback.
      (if (eq bongo-next-action 'bongo-play-random)
          (message (concat "Switched to random playback "
                           "(prefix argument forces)."))
        (setq bongo-next-action 'bongo-play-random)
        (message "Switched to random playback.")))))

(defun bongo-start ()
  "Start playing the current track in the nearest playlist buffer.
If something is already playing, do nothing.
If there is no current track, start playing the first track."
  (with-bongo-playlist-buffer
    (unless (bongo-playing-p)
      (bongo-play-line (or (bongo-point-at-current-track-line)
                           (bongo-point-at-first-track-line)
                           (error "No tracks in playlist"))))))

(defun bongo-stop (&optional toggle-interrupt)
  "Permanently stop playback in the nearest Bongo playlist buffer.
If `bongo-avoid-interrupting-playback' is non-nil,
  just set `bongo-next-action' to `bongo-stop'.
If TOGGLE-INTERRUPT (prefix argument if interactive) is non-nil,
  act as if `bongo-avoid-interrupting-playback' were reversed."
  (interactive "P")
  (with-bongo-playlist-buffer
    (if (not (bongo-xor bongo-avoid-interrupting-playback
                        toggle-interrupt))
        ;; We should interrupt playback.
        (when bongo-player
          (bongo-player-stop bongo-player))
      ;; We should not interrupt playback.
      (if (eq bongo-next-action 'bongo-stop)
          (message (concat "Playback will stop after the current track "
                           "(prefix argument forces)."))
        (setq bongo-next-action 'bongo-stop)
        (message "Playback will stop after the current track.")))))

(defun bongo-start/stop (&optional toggle-interrupt)
  "Start or stop playback in the nearest Bongo playlist buffer.
See `bongo-stop' for the meaning of TOGGLE-INTERRUPT."
  (interactive "P")
  (if (bongo-playing-p)
      (bongo-stop toggle-interrupt)
    (bongo-start)))

(defun bongo-pause/resume ()
  "Pause or resume playback in the nearest Bongo playlist buffer.
This functionality may not be available for all backends."
  (interactive)
  (with-bongo-playlist-buffer
    (if bongo-player
        (bongo-player-pause/resume bongo-player)
      (error "No active player"))))

(defun bongo-seek-forward (&optional n)
  "Seek N units forward in the currently playing track.
The time unit is currently backend-specific.
This functionality may not be available for all backends."
  (interactive "p")
  (let ((seeking-interactively (eq major-mode 'bongo-seek-mode)))
    (with-bongo-playlist-buffer
      (if (null bongo-player)
          (error "No active player")
        (bongo-player-seek-by bongo-player n)
        (unless seeking-interactively
          (when (and (bongo-player-elapsed-time bongo-player)
                     (bongo-player-total-time bongo-player))
            (bongo-show)))))))

(defun bongo-seek-backward (&optional n)
  "Seek N units backward in the currently playing track.
The time unit it currently backend-specific.
This functionality may not be available for all backends."
  (interactive "p")
  (let ((seeking-interactively (eq major-mode 'bongo-seek-mode)))
    (with-bongo-playlist-buffer
     (if (null bongo-player)
         (error "No active player")
       (bongo-player-seek-by bongo-player (- n))
       (unless seeking-interactively
         (when (and (bongo-player-elapsed-time bongo-player)
                    (bongo-player-total-time bongo-player))
           (bongo-show)))))))

(defun bongo-seek-to (position)
  "Seek to POSITION in the currently playing track.
The time unit is currently backend-specific.
This functionality may not be available for all backends."
  (interactive
   (with-bongo-playlist-buffer
     (if bongo-player
         (list
          (let ((unit (bongo-player-get bongo-player 'seek-unit)))
            (cond
             ((null unit)
              (error "This player does not support seeking"))
             ((eq unit 'frames)
              (read-number "Seek to (in frames): "))
             ((eq unit 'seconds)
              (let ((total-time (bongo-player-total-time bongo-player)))
                (bongo-until
                    (bongo-parse-time
                     (read-string
                      (if (null total-time)
                          "Seek to (in seconds or MM:SS): "
                        (format "Seek to (max %s): "
                                (bongo-format-seconds total-time)))))
                  (message "Please enter a number or HH:MM:SS.")
                  (sit-for 2)))))))
       (error "No active player"))))
  (let ((seeking-interactively (eq major-mode 'bongo-seek-mode)))
    (with-bongo-playlist-buffer
     (if (null bongo-player)
         (error "No active player")
       (bongo-player-seek-to bongo-player position)
       (unless seeking-interactively
         (when (and (bongo-player-elapsed-time bongo-player)
                    (bongo-player-total-time bongo-player))
           (bongo-show)))))))


;;;; Interactive seeking

(defcustom bongo-seek-electric-mode t
  "Run Bongo Seek electrically, in the echo area.
Electric mode saves some space, but uses its own command loop."
  :type 'boolean
  :group 'bongo)

(defvar bongo-seeking-electrically nil
  "Non-nil in the dynamic scope of electric `bongo-seek'.
That is, when `bongo-seek-electric-mode' is non-nil.")

(defface bongo-seek-bar '((t nil))
  "Face used for the indicator bar in Bongo Seek mode."
  :group 'bongo-faces)

(defface bongo-filled-seek-bar
  '((t (:inverse-video t :bold t :inherit bongo-seek-bar)))
  "Face used for the filled part of the indicator bar."
  :group 'bongo-faces)

(defface bongo-unfilled-seek-bar
  '((t (:inherit bongo-seek-bar)))
  "Face used for the unfilled part of the indicator bar."
  :group 'bongo-faces)

(defface bongo-seek-message '((t nil))
  "Face used for messages in Bongo Seek mode."
  :group 'bongo-faces)

(defvar bongo-seek-buffer nil
  "The current interactive Bongo Seek buffer, or nil.")

(defun bongo-seek-quit ()
  "Quit Bongo Seek mode."
  (interactive)
  (if bongo-seek-electric-mode
      (throw 'bongo-seek-done nil)
    (ignore-errors
      (while (get-buffer-window bongo-seek-buffer)
        (delete-window (get-buffer-window bongo-seek-buffer))))
    (kill-buffer bongo-seek-buffer)
    (setq bongo-seek-buffer nil)))

(defun bongo-seek-mode ()
  "Major mode for interactively seeking in Bongo tracks.

\\{bongo-seek-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (setq major-mode 'bongo-seek-mode)
  (setq mode-name "Bongo Seek")
  (use-local-map bongo-seek-mode-map)
  (run-mode-hooks 'bongo-seek-mode-hook))

(defvar bongo-seek-mode-map
  (let ((map (make-sparse-keymap))
        (backward-more (lambda (n)
                         (interactive "p")
                         (bongo-seek-backward (* n 10))))
        (forward-more (lambda (n)
                        (interactive "p")
                        (bongo-seek-forward (* n 10)))))
    (suppress-keymap map)
    (define-key map "b" 'bongo-seek-backward)
    (define-key map "f" 'bongo-seek-forward)
    (define-key map "\C-b" 'bongo-seek-backward)
    (define-key map "\C-f" 'bongo-seek-forward)
    (define-key map "\M-b" backward-more)
    (define-key map "\M-f" forward-more)
    (define-key map [left] 'bongo-seek-backward)
    (define-key map [right] 'bongo-seek-forward)
    (define-key map [(control left)] backward-more)
    (define-key map [(control right)] forward-more)
    (define-key map [(meta left)] backward-more)
    (define-key map [(meta right)] forward-more)
    ;; XXX: This does not work in the electric command loop,
    ;;      because it rebinds the normal editing keys:
    ;;
    ;;         (define-key map "t" 'bongo-seek-to)
    (define-key map "a" 'bongo-replay-current)
    (define-key map "e" 'bongo-play-next)
    (define-key map "\C-a" 'bongo-replay-current)
    (define-key map "\C-e" 'bongo-play-next)
    (define-key map [home] 'bongo-replay-current)
    (define-key map [end] 'bongo-play-next)
    (define-key map "p" 'bongo-play-previous)
    (define-key map "n" 'bongo-play-next)
    (define-key map "\C-p" 'bongo-play-previous)
    (define-key map "\C-n" 'bongo-play-next)
    (define-key map [up] forward-more)
    (define-key map [down] backward-more)
    (define-key map "\M-p" 'bongo-play-previous)
    (define-key map "\M-n" 'bongo-play-next)
    (define-key map " " 'bongo-pause/resume)
    (define-key map "\C-c\C-a" 'bongo-replay-current)
    (define-key map "\C-c\C-i" 'bongo-perform-next-action)
    (define-key map "\C-c\C-p" 'bongo-play-previous)
    (define-key map "\C-c\C-n" 'bongo-play-next)
    (define-key map "\C-c\C-r" 'bongo-play-random)
    (define-key map "\C-c\C-s" 'bongo-start/stop)
    (define-key map "l" 'bongo-seek-redisplay)
    (define-key map "g" 'bongo-seek-quit)
    (define-key map "\C-g" 'bongo-seek-quit)
    (define-key map "\C-m" 'bongo-seek-quit)
    (define-key map "q" 'bongo-seek-quit)
    (define-key map "s" 'bongo-seek-quit)
    (define-key map [escape escape] 'bongo-seek-quit)
    map)
  "Keymap for Bongo Seek mode.")

(defvar bongo-seek-redisplaying nil
  "Non-nil in the dynamic scope of `bongo-seek-redisplay'.")

(defun bongo-seek-redisplay ()
  "Update the Bongo Seek buffer to reflect the current track position."
  (interactive)
  (unless bongo-seek-redisplaying
    (let ((bongo-seek-redisplaying t))
      (let ((inhibit-read-only t))
        (set-buffer bongo-seek-buffer)
        (when (and bongo-seeking-electrically
                   (current-message))
          (sit-for 2)
          (message nil))
        (delete-region (point-min) (point-max))
        (when (and (bongo-playing-p)
                   (bongo-elapsed-time))
          (insert " ")
          (insert (bongo-format-seconds (bongo-elapsed-time)))
          (insert " "))
        (let* ((end-string (when (and (bongo-playing-p)
                                      (bongo-remaining-time))
                             (concat " -" (bongo-format-seconds
                                           (bongo-remaining-time)))))
               (bar-start (point))
               (available-width (- (window-width)
                                   bar-start
                                   (length end-string)))
               (bar-width (if (and (bongo-playing-p)
                                   (bongo-elapsed-time)
                                   (bongo-total-time))
                              (round (* (/ (float (bongo-elapsed-time))
                                           (bongo-total-time))
                                        available-width))
                            available-width))
               (label (if (and (bongo-playing-p)
                               (bongo-elapsed-time)
                               (bongo-total-time))
                          (format " %d%% "
                                  (/ (* (bongo-elapsed-time) 100.0)
                                     (bongo-total-time)))
                        (cond ((not (bongo-playing-p))
                               " (no currently playing track) ")
                              ((null (bongo-total-time))
                               " (track length not available) ")
                              ((null (bongo-elapsed-time))
                               " (elapsed time not available) "))))
               (label-width (length label)))
          (insert-char ?\  available-width)
          (goto-char
           (+ bar-start
              (if (< bar-width label-width)
                  (1+ bar-width)
                (/ (1+ (- bar-width label-width)) 2))))
          (delete-char label-width)
          (insert label)
          (put-text-property bar-start (+ bar-start bar-width)
                             'face (if (and (bongo-playing-p)
                                            (bongo-elapsed-time)
                                            (bongo-total-time))
                                       'bongo-filled-seek-bar
                                     'bongo-seek-message))
          (put-text-property (+ bar-start bar-width)
                             (+ bar-start available-width)
                             'face 'bongo-unfilled-seek-bar)
          (when end-string
            (goto-char (point-max))
            (insert end-string))
          (goto-char (+ bar-start bar-width)))))))

;; This function was based on the function `calculator' from
;; calculator.el, which is copyrighted by the FSF.
(defun bongo-seek ()
  "Interactively seek in the current Bongo track."
  (interactive)
  (setq bongo-seek-buffer (get-buffer-create "*Bongo Seek*"))
  (if bongo-seek-electric-mode
      (unwind-protect
          (save-window-excursion
            (require 'electric)
            (message nil)
            (let ((echo-keystrokes 0)
                  (garbage-collection-messages nil)
                  (bongo-seeking-electrically t))
              (set-window-buffer (minibuffer-window) bongo-seek-buffer)
              (select-window (minibuffer-window))
              (let ((old-local-map (current-local-map))
                    (old-global-map (current-global-map)))
                (use-local-map nil)
                (use-global-map bongo-seek-mode-map)
                (setq major-mode 'bongo-seek-mode)
                (unwind-protect
                    (progn
                      (bongo-seek-redisplay)
                      (run-hooks 'bongo-seek-mode-hook)
                      (catch 'bongo-seek-done
                        (Electric-command-loop
                         'bongo-seek-done
                         ;; Avoid `noprompt' due to
                         ;; a bug in electric.el.
                         '(lambda () 'noprompt)
                         nil
                         (lambda (x y) (bongo-seek-redisplay)))))
                  (use-local-map old-local-map)
                  (use-global-map old-global-map)))))
        (when bongo-seek-buffer
          (kill-buffer bongo-seek-buffer)
          (setq bongo-seek-buffer nil)))
    (cond
     ((null (get-buffer-window bongo-seek-buffer))
      (let ((window-min-height 2)
            (split-window-keep-point nil))
        (select-window
         (split-window-vertically
          (if (and (fboundp 'face-attr-construct)
                   (plist-get (face-attr-construct 'modeline) :box))
              -3 -2)))
        (switch-to-buffer bongo-seek-buffer)))
     ((not (eq (current-buffer) bongo-seek-buffer))
      (select-window (get-buffer-window bongo-seek-buffer))))
    (bongo-seek-mode)
    (setq buffer-read-only t)
    (bongo-seek-redisplay)))


;;;; Inserting

(defun bongo-insert-line (&rest properties)
  "Insert a new line with PROPERTIES before the current line.
Externalize as many fields of the new line as possible and redisplay it.
Point is left immediately after the new line."
  (let ((inhibit-read-only t))
    (move-beginning-of-line nil)
    (insert-before-markers (apply 'propertize "\n" properties)))
  (forward-line -1)
  (bongo-externalize-fields)
  (if (bongo-empty-header-line-p)
      (bongo-delete-line)
    (bongo-redisplay-line)
    (if (or (bongo-header-line-p)
            (bongo-last-object-line-p)
            (>= (bongo-line-indentation)
                (save-excursion
                  (bongo-next-object-line)
                  (bongo-line-indentation))))
        (forward-line)
      (forward-line)
      (bongo-insert-header))))

(defun bongo-insert-header (&optional fields)
  "Insert a new header line with internal FIELDS.
FIELDS defaults to the external fields of the current line."
  (bongo-insert-line 'bongo-header t 'bongo-fields
                     (or fields (bongo-line-external-fields))))

(defun bongo-insert-file (file-name)
  "Insert a new track line corresponding to FILE-NAME.
If FILE-NAME names a directory, call `bongo-insert-directory-tree'.

Interactively, expand wildcards and insert all matching files,
unless `find-file-wildcards' is set to nil."
  (interactive (list (let ((file-string
                            (read-file-name "Insert file or directory tree: "
                                            default-directory nil nil
                                            (when (eq major-mode 'dired-mode)
                                              (dired-get-filename t)))))
                       (cond ((string-match "\\`/:" file-string)
                              (expand-file-name (substring file-string 2)))
                             ((null find-file-wildcards)
                              (expand-file-name file-string))
                             (t (file-expand-wildcards file-string t))))))
  (cond ((null file-name)
         (error "No matching files found"))
        ((consp file-name)
         (if (null (cdr file-name))
             (bongo-insert-file (car file-name))
           (let ((beginning (point)))
             (mapc 'bongo-insert-file file-name)
             (bongo-maybe-join-inserted-tracks beginning (point)))))
        ((file-directory-p file-name)
         (bongo-insert-directory-tree file-name))
        (t
         (bongo-insert-line 'bongo-file-name file-name)
         (when (and (interactive-p) (not (bongo-buffer-p)))
           (message "Inserted track: %s"
                    (bongo-format-infoset
                     (bongo-infoset-from-file-name file-name)))))))

(defun bongo-maybe-insert-album-cover (directory-name)
  "Insert the album cover in DIRECTORY-NAME, if one exists.
Album covers are files whose names are in `bongo-album-cover-file-names'."
  (let ((cover-file-name nil)
        (file-names bongo-album-cover-file-names))
    (while (and file-names (null cover-file-name))
      (let ((file-name (concat directory-name "/" (car file-names))))
        (when (file-exists-p file-name)
          (setq cover-file-name file-name)))
      (setq file-names (cdr file-names)))
    (when cover-file-name
      (let ((file-type-entry
             (assoc (downcase (file-name-extension cover-file-name))
                    '(("jpg" . jpeg) ("jpeg" . jpeg)
                      ("png" . png) ("gif" . gif)))))
        (when (null file-type-entry)
          (error "Unrecognized file name extension: %s" cover-file-name))
        (let ((cover-file-type (cdr file-type-entry))
              (inhibit-read-only t))
          (insert (propertize "[cover image]" 'display
                              `(image :type ,cover-file-type
                                      :file ,cover-file-name)))
          (insert "\n"))))))

(defun bongo-maybe-join-inserted-tracks (beg end)
  "Maybe run `bongo-join' repeatedly from BEG to END.
Only do it if `bongo-join-inserted-tracks' is non-nil."
  (when bongo-join-inserted-tracks
    (unless (markerp end)
      (setq end (move-marker (make-marker) end)))
    (goto-char beg)
    (bongo-ignore-movement-errors
      (bongo-snap-to-object-line)
      (while (< (point) end)
        (bongo-join 'skip)))))

(defun bongo-insert-directory (directory-name)
  "Insert a new track line for each file in DIRECTORY-NAME.
Only insert files that can be played by some backend, as determined by
the matchers returned by the function `bongo-backend-matchers'.

If `bongo-insert-album-covers' is non-nil, then for each directory
that contains a file whose name is in `bongo-album-cover-file-names',
insert the image in that file before the directory contents.

Do not examine subdirectories of DIRECTORY-NAME."
  (interactive (list (expand-file-name
                      (read-directory-name
                       "Insert directory: " default-directory nil t
                       (when (eq major-mode 'dired-mode)
                         (when (file-directory-p (dired-get-filename))
                           (dired-get-filename t)))))))
  (when (null (bongo-backend-matchers))
    (error "No backends are enabled; customize `bongo-enabled-backends'"))
  (with-bongo-buffer
    (when (not (file-directory-p directory-name))
      (error "File is not a directory: %s" directory-name))
    (when bongo-insert-album-covers
      (bongo-maybe-insert-album-cover directory-name))
    (let ((file-names (directory-files directory-name t "\\`[^.]")))
      (when (null file-names)
        (error "Directory contains no playable files"))
      (let ((beginning (point)))
        (dolist (file-name file-names)
          (when (bongo-backend-for-file file-name)
            (bongo-insert-file file-name)))
        (bongo-maybe-join-inserted-tracks beginning (point)))
      (when (and (interactive-p) (not (bongo-buffer-p)))
        (message "Inserted %d files." (length file-names))))))

(defvar bongo-insert-directory-tree-total-file-count nil
  "The total number of files to be inserted.
This variable is bound by `bongo-insert-directory-tree'.")

(defvar bongo-insert-directory-tree-current-file-count nil
  "The number of files inserted so far.
This variable is bound by `bongo-insert-directory-tree'
and modified by `bongo-insert-directory-tree-1'.")

(defun bongo-insert-directory-tree-1 (directory-name)
  "Helper function for `bongo-insert-directory-tree'."
  (when bongo-insert-album-covers
    (bongo-maybe-insert-album-cover directory-name))
  (let ((file-names (directory-files directory-name t "\\`[^.]")))
    (let ((bongo-inside-insert-directory-tree t))
      (dolist (file-name file-names)
        (if (file-directory-p file-name)
            (bongo-insert-directory-tree-1 file-name)
          (when (bongo-backend-for-file file-name)
            (bongo-insert-file file-name))
          (unless (zerop bongo-insert-directory-tree-total-file-count)
            (when (zerop (% bongo-insert-directory-tree-current-file-count 10))
              (message "Inserting directory tree...%d%%"
                       (/ (* 100 bongo-insert-directory-tree-current-file-count)
                          bongo-insert-directory-tree-total-file-count))))
          (setq bongo-insert-directory-tree-current-file-count
                (+ 1 bongo-insert-directory-tree-current-file-count)))))))

(defun bongo-insert-directory-tree (directory-name)
  "Insert a new track line for each file below DIRECTORY-NAME.
Only insert files that can be played by some backend, as determined by
the matchers returned by the function `bongo-backend-matchers'.

If `bongo-insert-album-covers' is non-nil, then for each directory
that contains a file whose name is in `bongo-album-cover-file-names',
insert the image in that file before the directory contents.

This function descends each subdirectory of DIRECTORY-NAME recursively."
  (interactive (list (expand-file-name
                      (read-directory-name
                       "Insert directory tree: "
                       default-directory nil t
                       (when (eq major-mode 'dired-mode)
                         (when (file-directory-p (dired-get-filename))
                           (dired-get-filename t)))))))
  (when (null (bongo-backend-matchers))
    (error "No backends are enabled; customize `bongo-enabled-backends'"))
  (when (not (file-directory-p directory-name))
    (error "File is not a directory: %s" directory-name))
  (message "Inserting directory tree...")
  (with-bongo-buffer
    (let ((beginning (point))
          (bongo-insert-directory-tree-current-file-count 0)
          (bongo-insert-directory-tree-total-file-count
           (with-temp-buffer
             (insert directory-name)
             (call-process-region
              (point-min) (point-max) "sh" t t nil
              "-c" "xargs -0i find {} -type f -o -type l | wc -l")
             (string-to-number (buffer-string)))))
      (bongo-insert-directory-tree-1 directory-name)
      (bongo-maybe-join-inserted-tracks beginning (point))))
  (message "Inserting directory tree...done"))

(defun bongo-insert-uri (uri)
  "Insert a new track line corresponding to URI."
  (interactive
   (list (let* ((default
                  (or (and (x-selection-exists-p)
                           (let ((primary (x-get-selection)))
                             (and (bongo-uri-p primary) primary)))
                      (and (x-selection-exists-p 'CLIPBOARD)
                           (let ((clipboard (x-get-clipboard)))
                             (and (bongo-uri-p clipboard) clipboard)))))
                (default-string (when default
                                  (format " (default `%s')" default))))
           (read-string (concat "Insert URI" default-string ": ")
                        nil nil default))))
  (bongo-insert-line 'bongo-file-name uri)
  (when (and (interactive-p) (not (bongo-buffer-p)))
    (message "Inserted URI: %s"
             (bongo-format-infoset
              (bongo-infoset-from-file-name uri)))))


;;;; Drag-and-drop support

(defun bongo-enable-dnd-support ()
  "Install the Bongo drag-and-drop handler for the current buffer."
  (interactive)
  (set (make-local-variable 'dnd-protocol-alist)
       '(("" . bongo-dnd-insert-uri)))
  (when (interactive-p)
    (message "Bongo drag-and-drop support enabled")))

(defun bongo-disable-dnd-support ()
  "Remove the Bongo drag-and-drop handler for the current buffer."
  (interactive)
  (kill-local-variable 'dnd-protocol-alist)
  (when (interactive-p)
    (message "Bongo drag-and-drop support disabled")))

(defcustom bongo-dnd-support t
  "Whether to enable drag-and-drop support in Bongo buffers.
Setting this variable normally affects only new Bongo buffers,
  but setting it through Custom also affects existing buffers.
To manually enable or disable Bongo drag-and-drop support, use
  `bongo-enable-dnd-support' and `bongo-disable-dnd-support'."
  :type 'boolean
  :initialize 'custom-initialize-default
  :set (lambda (name value)
         (dolist (buffer (if custom-local-buffer
                             (list (current-buffer))
                           (buffer-list)))
           (when (bongo-buffer-p buffer)
             (with-current-buffer buffer
               (if value
                   (bongo-enable-dnd-support)
                 (bongo-disable-dnd-support)))))
         (set-default name value))
  :group 'bongo)

(defcustom bongo-dnd-destination 'before-point
  "Where to insert items dragged and dropped into Bongo buffers.
If `before-point' or `after-point', insert dropped items before or after
  the line at point (or, if `mouse-yank-at-point' is nil, at the position
  of the mouse pointer).
If `end-of-buffer' or anything else, append to the end of the buffer."
  :type '(choice (const :tag "Insert before line at point (or mouse)"
                        before-point)
                 (const :tag "Insert after line at point (or mouse)"
                        after-point)
                 (other :tag "Append to end of buffer"
                        end-of-buffer))
  :group 'bongo)

(defun bongo-dnd-insert-uri (uri &optional action)
  "Insert URI at the current drag and drop destination.
If URI names a local file, insert it as a local file name.
If URI is not actually a URI, do nothing.
ACTION is ignored."
  (when (bongo-uri-p uri)
    (let* ((local-file-uri (dnd-get-local-file-uri uri))
           (local-file-name
            (or (when local-file-uri
                  ;; Due to a bug, `dnd-get-local-file-name'
                  ;; always returns nil without MUST-EXIST.
                  (dnd-get-local-file-name local-file-uri 'must-exist))
                (dnd-get-local-file-name uri 'must-exist))))
      (goto-char (case bongo-dnd-destination
                   (before-point (bongo-point-before-line))
                   (after-point (bongo-point-after-line))
                   (otherwise (point-max))))
      (if (not local-file-name)
          (bongo-insert-uri uri)
        (bongo-insert-file local-file-name)
        (when (eq bongo-dnd-destination 'after-point)
          (bongo-previous-object-line))))))


;;;; Collapsing and expanding

(defun bongo-collapse (&optional skip)
  "Collapse the section below the header line at point.
If point is not on a header line, collapse the section at point.

If SKIP is nil, leave point at the header line.
If SKIP is non-nil, leave point at the first object line after the section.
If point is neither on a header line nor in a section,
  and SKIP is nil, signal an error.
If called interactively, SKIP is always non-nil."
  (interactive "p")
  (when line-move-ignore-invisible
    (bongo-skip-invisible))
  (unless (bongo-header-line-p)
    (bongo-backward-up-section))
  (let ((line-move-ignore-invisible nil))
    (bongo-line-set-property 'bongo-collapsed t)
    (bongo-redisplay-line)
    (let ((end (bongo-point-after-object)))
      (forward-line 1)
      (let ((inhibit-read-only t))
        (put-text-property (point) end 'invisible t))
      (if (not skip)
          (forward-line -1)
        (goto-char end)
        (bongo-snap-to-object-line 'no-error)))))

(defun bongo-expand (&optional skip)
  "Expand the section below the header line at point.

If SKIP is nil, leave point at the header line.
If SKIP is non-nil, leave point at the first object line after the section.
If point is not on a header line or the section below the header line
  is not collapsed, and SKIP is nil, signal an error.
If called interactively, SKIP is always non-nil."
  (interactive "p")
  (when line-move-ignore-invisible
    (bongo-skip-invisible))
  (unless (bongo-header-line-p)
    (error "Not on a header line"))
  (unless (bongo-collapsed-header-line-p)
    (error "This section is not collapsed"))
  (let ((start (point))
        (inhibit-read-only t)
        (line-move-ignore-invisible nil))
    (bongo-line-remove-property 'bongo-collapsed)
    (bongo-redisplay-line)
    (put-text-property (bongo-point-after-line)
                       (bongo-point-after-object)
                       'invisible nil)
    (let ((indentation (bongo-line-indentation)))
      (bongo-ignore-movement-errors
        (bongo-next-object-line)
        (while (> (bongo-line-indentation) indentation)
          (if (not (bongo-collapsed-header-line-p))
              (bongo-next-object-line)
            (bongo-collapse 'skip)
            (bongo-snap-to-object-line)))))
    (when (not skip)
      (goto-char start))))

(defun bongo-toggle-collapsed ()
  "Collapse or expand the section at point.
If point is on a header line, operate on the section below point.
Otherwise, if point is in a section, operate on the section around point.
If point is neither on a header line nor in a section, signal an error."
  (interactive)
  (when line-move-ignore-invisible
    (bongo-skip-invisible))
  (condition-case nil
      (when (not (bongo-header-line-p))
        (bongo-backward-up-section))
    (error (error "No section here")))
  (if (bongo-collapsed-header-line-p)
      (bongo-expand)
    (bongo-collapse)))


;;;; Joining and splitting

(defun bongo-join-region (beg end &optional fields)
  "Join all tracks between BEG and END by externalizing FIELDS.
If FIELDS is nil, externalize all common fields between BEG and END.
If there are no common fields, or the fields are already external,
  or the region contains less than two lines, signal an error.
This function creates a new header if necessary."
  (interactive "r")
  (let ((line-move-ignore-invisible nil))
    (when (null fields)
      (unless (setq fields (bongo-common-fields-in-region beg end))
        (error "Cannot join tracks: no common fields")))
    (when (= 0 (bongo-region-line-count beg end))
      (error "Cannot join tracks: region empty"))
    (when (bongo-fields-external-in-region-p beg end fields)
      (error "Cannot join tracks: already joined"))
    (when (= 1 (bongo-region-line-count beg end))
      (error "Cannot join tracks: need more than one"))
    (save-excursion
      (setq end (move-marker (make-marker) end))
      (goto-char beg)
      (beginning-of-line)
      (let ((indent (length fields)))
        (bongo-ignore-movement-errors
          (while (< (point) end)
            (when (< (bongo-line-indentation) indent)
              (bongo-line-set-external-fields fields))
            (bongo-next-object-line))))
      (move-marker end nil)
;;;     (when (bongo-redundant-header-line-p)
;;;       (bongo-delete-line))
      (goto-char beg)
      (bongo-insert-header))))

(defun bongo-join (&optional skip)
  "Join the fields around point or in the region.
If the region is active, delegate to `bongo-join-region'.
Otherwise, find all common fields at point, and join all tracks around
point that share those fields.  (See `bongo-common-fields-at-point'.)

If SKIP is nil, leave point at the newly created header line.
If SKIP is non-nil, leave point at the first object line after
  the newly created section.
If there are no common fields at point and SKIP is nil, signal an error.
When called interactively, SKIP is always non-nil."
  (interactive "p")
  (if (bongo-region-active-p)
      (bongo-join-region (region-beginning) (region-end))
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (let* ((line-move-ignore-invisible nil)
           (fields (bongo-common-fields-at-point)))
      (if (null fields)
          (if skip
              (progn (bongo-snap-to-object-line)
                     (or (bongo-next-object-line 'no-error)
                         (bongo-forward-expression)))
            (error "No common fields at point"))
        (let ((values (bongo-line-field-values fields))
              (before (bongo-point-before-line))
              (after (bongo-point-after-line)))
          (save-excursion
            (while (and (bongo-previous-object-line 'no-error)
                        (equal values (bongo-line-field-values fields)))
              (setq before (bongo-point-before-line))))
          (save-excursion
            (while (and (bongo-next-object-line 'no-error)
                        (equal values (bongo-line-field-values fields)))
              (setq after (bongo-point-after-line))))
          (setq after (move-marker (make-marker) after))
          (bongo-join-region before after fields)
          (when skip
            (goto-char after))
          (move-marker after nil)
          (bongo-snap-to-object-line 'no-error))))))

(defun bongo-split (&optional skip)
  "Split the section below the header line at point.
If point is not on a header line, split the section at point.

If SKIP is nil, leave point at the first object in the section.
If SKIP is non-nil, leave point at the first object after the section.
If point is neither on a header line nor in a section,
  and SKIP is nil, signal an error.
If called interactively, SKIP is always non-nil."
  (interactive "p")
  (when (not (bongo-object-line-p))
    (or (bongo-previous-object-line 'no-error)
        (error "No section or track here")))
  (when (and (bongo-track-line-p)
             (bongo-line-indented-p))
    (bongo-backward-up-section))
  (if (bongo-track-line-p)
      (if skip
          (or (bongo-next-object-line 'no-error)
              (bongo-forward-expression))
        (error "No section here"))
    (when (bongo-collapsed-header-line-p)
      (bongo-expand))
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (let ((line-move-ignore-invisible nil))
      (let ((fields (bongo-line-internal-fields))
            (end (move-marker (make-marker) (bongo-point-after-object))))
        (bongo-delete-line)
        (let ((start (point)))
          (while (< (point) end)
            (let* ((previous (point))
                   (old-external
                    (bongo-line-external-fields))
                   (new-external
                    (bongo-set-difference old-external fields)))
              (condition-case nil
                  (bongo-next-object)
                (bongo-movement-error (goto-char end)))
              (bongo-line-set-external-fields new-external previous)))
          (move-marker end nil)
          (when (not skip)
            (goto-char start))
          (bongo-snap-to-object-line 'no-error))))))


;;;; Displaying

(defun bongo-facify (string &rest new-faces)
  "Add NEW-FACES to the `face' property of STRING.
For each character in STRING, if the value of the `face' property is
a list, append NEW-FACES to the old value and make that the new value.
If the value is a symbol, treat it as if it were a singleton list."
  (prog1 string
    (let ((index 0))
      (while index
        (let ((next-index (next-single-property-change index 'face string))
              (old-faces (get-text-property index 'face string)))
          (put-text-property index (or next-index (length string))
                             'face (append new-faces old-faces) string)
          (setq index next-index))))))

(defun bongo-redisplay-line (&optional point)
  "Redisplay the line at POINT, preserving semantic text properties."
  (bongo-goto-point point)
  (when line-move-ignore-invisible
    (bongo-skip-invisible))
  (let ((inhibit-read-only t)
        (indentation (bongo-line-indentation))
        (infoset (bongo-line-internal-infoset))
        (header (bongo-header-line-p))
        (collapsed (bongo-collapsed-header-line-p))
        (invisible (bongo-line-get-property 'invisible))
        (currently-playing (bongo-currently-playing-track-line-p))
        (played (bongo-played-track-line-p))
        (properties (bongo-line-get-semantic-properties)))
    (save-excursion
      (bongo-clear-line)
      (dotimes (dummy indentation)
        (insert bongo-indentation-string))
      (let ((content (apply 'propertize (bongo-format-infoset infoset)
                            'follow-link t 'mouse-face 'highlight
                            (when invisible
                              (list 'invisible invisible)))))
        (insert
         (cond (header
                (bongo-format-header content collapsed))
               (currently-playing
                (bongo-facify content 'bongo-currently-playing-track))
               (played
                (bongo-facify content 'bongo-played-track))
               (t content))))
      (bongo-line-set-properties properties))))

(defun bongo-redisplay-region (beg end)
  "Redisplay the Bongo objects in the region."
  (interactive "r")
  (unless (bongo-buffer-p)
    (error "Not a Bongo buffer"))
  (let ((target-string (if (and (= beg (point-min))
                                (= end (point-max)))
                           "buffer" "region"))
        (line-move-ignore-invisible nil)
        (end-marker (move-marker (make-marker) end)))
    (save-excursion
     (when (interactive-p)
       (message "Rendering %s..." target-string))
     (goto-char beg)
     (bongo-ignore-movement-errors
       (bongo-snap-to-object-line)
       (while (< (point) end-marker)
         (when (interactive-p)
           (message "Rendering %s...%d%%" target-string
                    (/ (* 100 (point)) (point-max))))
         (bongo-redisplay-line)
         (bongo-next-object-line)))
     (when (interactive-p)
       (message "Rendering %s...done" target-string)))))

(defun bongo-redisplay ()
  "Redisplay the current Bongo buffer.
If the region is active, redisplay just the objects in the region."
  (interactive)
  (if (bongo-region-active-p)
      (bongo-redisplay-region (region-beginning) (region-end))
    (bongo-redisplay-region (point-min) (point-max))))

(defun bongo-recenter ()
  "Move point to the currently playing track and recenter.
If no track is currently playing, just call `recenter'."
  (interactive)
  (let ((original-window (selected-window))
        (window (get-buffer-window (bongo-playlist-buffer) t)))
    (when window
      (select-window window)
      (bongo-goto-point (or (bongo-point-at-current-track-line)
                            (bongo-point-at-queued-track-line)))
      (recenter)
      (select-window original-window))))

(defun bongo-parse-time (time)
  "Return the total number of seconds of TIME, or nil.
If TIME is a string of the form [[H:]M:]S[.F], where H, M, S and F
  may each be any number of digits, return 3600H + 60M + S.F.
If TIME is any other string, return nil."
  (when (string-match
         (eval-when-compile
           (rx string-start
               (optional (optional
                          ;; Hours.
                          (submatch (one-or-more digit)) ":")
                         ;; Minutes.
                         (submatch (one-or-more digit)) ":")
               ;; Seconds.
               (submatch (one-or-more digit)
                         (optional "." (one-or-more digit)))
               string-end))
         time)
    (let ((hours (match-string 1 time))
          (minutes (match-string 2 time))
          (seconds (match-string 3 time)))
      (+ (if (null hours) 0
           (* 3600 (string-to-number hours)))
         (if (null minutes) 0
           (* 60 (string-to-number minutes)))
         (if (null seconds) 0
           (string-to-number seconds))))))

(defun bongo-format-seconds (n)
  "Return a user-friendly string representing N seconds.
If N < 3600, the string will look like \"mm:ss\".
Otherwise, it will look like \"hhh:mm:ss\", the first field
  being arbitrarily long.
If N is nil, just return nil."
  (when n
    (setq n (floor n))
    (let ((hours (/ n 3600))
          (minutes (% (/ n 60) 60))
          (seconds (% n 60)))
      (let ((result (format "%02d:%02d" minutes seconds)))
        (unless (zerop hours)
          (setq result (format "%d:%s" hours result)))
        result))))

(defun bongo-show (&optional insert-flag)
  "Display what Bongo is playing in the minibuffer.
If INSERT-FLAG (prefix argument if interactive) is non-nil,
  insert the description at point.
Return the description string."
  (interactive "P")
  (let* ((player (with-bongo-playlist-buffer
                   (or bongo-player
                       (error "No currently playing track"))))
         (elapsed-time (when player (bongo-player-elapsed-time player)))
         (total-time (when player (bongo-player-total-time player)))
         (description (bongo-format-infoset
                       (bongo-player-infoset player)))
         (string (if (not (and elapsed-time total-time))
                     description
                   (format "%s [%s/%s]" description
                           (bongo-format-seconds elapsed-time)
                           (bongo-format-seconds total-time)))))
    (prog1 string
      (if insert-flag
          (insert string)
        (message "%s" string)))))


;;;; Killing and yanking commands

(defun bongo-kill-line ()
  "In Bongo, kill the current section, track, or line.
If the current line is a header line, kill the whole section.
If the current line is a track line, kill the track.
Otherwise, just kill the line as `kill-line' would.
See also `bongo-copy-line-as-kill'."
  (interactive)
  (let ((inhibit-read-only t))
    (cond
     ((bongo-track-line-p)
      (when (bongo-current-track-line-p)
        (bongo-unset-current-track-position))
      (when (bongo-queued-track-line-p)
        ;; Use a text property to communicate with
        ;; `bongo-clean-up-after-insertion'.
        (bongo-line-set-property 'bongo-queued-track-flag t)
        (bongo-unset-queued-track-position)
        (bongo-line-remove-property 'bongo-queued-track-flag))
      (let ((kill-whole-line t))
        (beginning-of-line)
        (when line-move-ignore-invisible
          (bongo-skip-invisible))
        (kill-line)))
     ((bongo-header-line-p)
      (save-excursion
        (beginning-of-line)
        (when line-move-ignore-invisible
          (bongo-skip-invisible))
        (let ((line-move-ignore-invisible nil))
          (kill-region (point) (bongo-point-after-object)))))
     (t
      (kill-line)))))

(defun bongo-copy-line-as-kill (&optional skip)
  "In Bongo, save the current object as if killed, but don't kill it.
If the current line is a header line, copy the whole section.
If the current line is a track line, copy the track.
Otherwise, just copy the current line.

If SKIP is non-nil, move point past the copied text after copying.
Interactively, SKIP is always non-nil.

See also `bongo-kill-line'."
  (interactive "p")
  (when (eq last-command 'bongo-copy-line-as-kill)
    (append-next-kill))
  (let ((end (if (bongo-object-line-p)
                 (bongo-point-after-object)
               (bongo-point-after-line))))
    (copy-region-as-kill (bongo-point-before-line) end)
    (when skip
      (goto-char end))))

(defun bongo-kill-region (&optional beg end)
  "In Bongo, kill the lines between point and mark.
If the region ends inside a section, kill that whole section.
See `kill-region'."
  (interactive "r")
  (setq end (move-marker (make-marker) end))
  (save-excursion
    (goto-char beg)
    (while (progn (bongo-kill-line)
                  (< (point) end))
      (append-next-kill)))
  (move-marker end nil))

(defun bongo-clean-up-after-insertion (beg end)
  (let ((end (move-marker (make-marker) end))
        (line-move-ignore-invisible nil))
    (save-excursion
      (goto-char beg)
      (bongo-ignore-movement-errors
        (bongo-snap-to-object-line)
        (while (< (point) end)
          (let ((player (bongo-line-get-property 'bongo-player)))
            (when player
              (if (and (eq player bongo-player)
                       (null (bongo-point-at-current-track-line)))
                  (bongo-set-current-track-position (point-at-bol))
                (bongo-line-remove-property 'bongo-player))))
          (unless (bongo-point-at-queued-track-line)
            (when (bongo-line-get-property 'bongo-queued-track-flag)
              (bongo-line-remove-property 'bongo-queued-track-flag)
              (bongo-set-queued-track-position)))
          (bongo-next-object-line)))
      ;; These headers will stay if they are needed,
      ;; or disappear automatically otherwise.
      (goto-char beg)
      (bongo-insert-header)
      (goto-char end)
      (unless (bongo-last-object-line-p)
        (bongo-insert-header))
      ;; In case the upper header does disappear,
      ;; we need to merge backwards to connect.
      (bongo-ignore-movement-errors
        (bongo-snap-to-object-line)
        (bongo-externalize-fields))
      (move-marker end nil))))

(defun bongo-insert (text &optional redisplay-flag)
  (let ((inhibit-read-only t))
    (beginning-of-line)
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (let ((beg (point)))
      (insert text)
      (when redisplay-flag
        (bongo-redisplay-region beg (point)))
      (bongo-clean-up-after-insertion beg (point)))))

(defun bongo-insert-comment (text)
  (bongo-insert (bongo-facify text 'bongo-comment)))

(defun bongo-insert-warning (text)
  (bongo-insert (bongo-facify text 'bongo-warning)))

(defun bongo-yank (&optional arg)
  "In Bongo, reinsert the last sequence of killed lines.
See `yank'."
  (interactive "P")
  (let ((inhibit-read-only t))
    (beginning-of-line)
    (when line-move-ignore-invisible
      (bongo-skip-invisible))
    (let ((yank-excluded-properties
           (remq 'invisible yank-excluded-properties)))
      (yank arg))
    (bongo-clean-up-after-insertion
     (region-beginning) (region-end))))

;; XXX: This definitely does not work properly.
(defun bongo-yank-pop (&optional arg)
  "In Bongo, replace the just-yanked lines with different ones.
See `yank-pop'."
  (interactive "P")
  (let ((inhibit-read-only t))
    (yank-pop arg)
    (bongo-externalize-fields)))

;; XXX: This probably does not work properly.
(defun bongo-undo (&optional arg)
  "In Bongo, undo some previous changes.
See `undo'."
  (interactive "P")
  (let ((inhibit-read-only t))
    (undo arg)))


;;;; Enqueuing commands

(defun bongo-enqueue-text (mode text)
  "Insert TEXT into the Bongo playlist.
If MODE is `insert', insert TEXT just below the current track.
If MODE is `append', append TEXT to the end of the playlist."
  (let ((insertion-point
         (with-bongo-playlist-buffer
           (save-excursion
             (ecase mode
               (insert (if (bongo-point-at-current-track-line)
                           (bongo-goto-point
                            (bongo-point-after-line
                             (bongo-point-at-current-track-line)))
                         (goto-char (point-min))))
               (append (goto-char (point-max))))
             (prog1 (point)
               (remove-text-properties 0 (length text)
                                       (list 'invisible nil
                                             'bongo-collapsed nil)
                                       text)
               (bongo-insert text 'redisplay))))))
    (prog1 insertion-point
      (when (and (bongo-library-buffer-p)
                 (or (get-buffer-window (bongo-playlist-buffer))
                     bongo-display-playlist-after-enqueue))
        (let ((original-window (selected-window)))
          (select-window (display-buffer (bongo-playlist-buffer)))
          (goto-char insertion-point)
          (recenter)
          (select-window original-window))))))

;;; The following functions ignore point and operate on all
;;; tracks in a given region.

(defun bongo-enqueue-region (mode beg end)
  "Insert the tracks between BEG and END into the Bongo playlist.
If MODE is `insert', insert the tracks just below the current track.
If MODE is `append', append the tracks to the end of the playlist."
  (let* ((original-buffer (current-buffer))
         (text (with-temp-buffer
                 ;; This is complicated because we want to remove the
                 ;; `bongo-external-fields' property from all tracks
                 ;; and headers before enqueuing them, but we want to
                 ;; keep the property for everything *within* sections.
                 (let ((temp-buffer (current-buffer))
                       (line-move-ignore-invisible nil))
                   (set-buffer original-buffer)
                   (goto-char (bongo-point-before-line beg))
                   (while (< (point) end)
                     (let ((point-before-first-line (point))
                           (point-after-first-line (bongo-point-after-line)))
                       (when (and (prog1 (bongo-object-line-p)
                                    (bongo-forward-expression))
                                  (> (point) end))
                         (goto-char end))
                       (when (> (point) end)
                         (goto-char (bongo-point-at-bol-forward end)))
                       (let ((first-line
                              (buffer-substring point-before-first-line
                                                point-after-first-line))
                             (other-lines
                              (buffer-substring point-after-first-line
                                                (point))))
                         (remove-text-properties
                          0 (length first-line)
                          (list 'bongo-external-fields nil)
                          first-line)
                         (with-current-buffer temp-buffer
                           (insert first-line)
                           (insert other-lines)))))
                   (with-current-buffer temp-buffer
                     (buffer-string))))))
    (bongo-enqueue-text mode text)))

(defun bongo-insert-enqueue-region (beg end)
  "Insert the region just below the current Bongo track."
  (interactive "r")
  (bongo-enqueue-region 'insert beg end))

(defun bongo-append-enqueue-region (beg end)
  "Append the region to the end of the Bongo playlist."
  (interactive "r")
  (bongo-enqueue-region 'append beg end))

;;; The following functions operate on a given number of
;;; tracks or sections right after point.

(defun bongo-enqueue-line (mode &optional n skip)
  "Insert the next N tracks or sections into the Bongo playlist.
Afterwards, if SKIP is non-nil, move point past the enqueued objects.
If MODE is `insert', insert just below the current track.
If MODE is `append', append to the end of the playlist.
Return the playlist position of the newly-inserted text."
  (when (null n)
    (setq n 1))
  (when line-move-ignore-invisible
    (bongo-skip-invisible))
  (let ((line-move-ignore-invisible nil))
    (let ((beg (point))
          (end (dotimes (dummy (abs n) (point))
                 (bongo-goto-point
                  (if (> n 0)
                      (bongo-point-after-object)
                    (bongo-point-before-previous-object))))))
      (when (not skip)
        (goto-char beg))
      (bongo-enqueue-region mode (min beg end) (max beg end)))))

(defun bongo-insert-enqueue-line (&optional n)
  "Insert the next N tracks or sections just below the current track.
When called interactively, leave point after the enqueued tracks or sections.
Return the playlist position of the newly-inserted text."
  (interactive "p")
  (bongo-enqueue-line 'insert n (called-interactively-p)))

(defun bongo-append-enqueue-line (&optional n)
  "Append the next N tracks or sections to the Bongo playlist buffer.
When called interactively, leave point after the enqueued tracks or sections.
Return the playlist position of the newly-inserted text. "
  (interactive "p")
  (bongo-enqueue-line 'append n (called-interactively-p)))

;;; The following functions are contingent on whether or not
;;; the region is active.  That is, whether Transient Mark
;;; mode is enabled and `mark-active' is non-nil.
;;;
;;; Note that recent Emacs versions let you temporarily
;;; enable Transient Mark mode by hitting C-SPC C-SPC.

(defun bongo-enqueue (mode &optional n)
  "Insert the next N tracks or sections into the Bongo playlist.
If the region is active, ignore N and enqueue the region instead.
If MODE is `insert', insert just below the current track.
If MODE is `append', append to the end of the playlist."
  (if (bongo-region-active-p)
      (bongo-enqueue-region mode (region-beginning) (region-end))
    (bongo-enqueue-line mode n 'skip)))

(defun bongo-append-enqueue (&optional n)
  "Append the next N tracks or sections to the Bongo playlist buffer.
If the region is active, ignore N and enqueue the region instead."
  (interactive "p")
  (bongo-enqueue 'append n))

(defun bongo-insert-enqueue (&optional n)
  "Insert the next N tracks or sections just below the current track.
If the region is active, ignore N and enqueue the region instead."
  (interactive "p")
  (bongo-enqueue 'insert n))


;;;; Miscellaneous commands

(defun bongo-transpose-forward ()
  "Transpose the section or track at point forward."
  (interactive)
  (let ((beg (bongo-point-before-line))
        (mid (bongo-point-at-next-object)))
    (when (null mid)
      (error "No track or section at point"))
    (let ((end (bongo-point-after-object mid)))
      (when (null end)
        (signal 'bongo-no-next-object nil))
      (let ((inhibit-read-only t))
        (transpose-regions beg mid mid end)))))

(defun bongo-transpose-backward ()
  "Transpose the section or track at point backward."
  (interactive)
  (save-excursion
    (bongo-previous-object)
    (condition-case nil
        (bongo-transpose-forward)
      (bongo-no-next-object
       (error "No track or section at point")))))

(defun bongo-delete-empty-sections ()
  "Delete all empty sections from the current Bongo buffer."
  (let ((inhibit-read-only t)
        (line-move-ignore-invisible nil))
    (save-excursion
      (goto-char (point-min))
      (bongo-ignore-movement-errors
        (while (bongo-snap-to-object-line)
          (if (not (bongo-empty-section-p))
              (bongo-next-object-line)
            (bongo-delete-line)))))))

(defun bongo-delete-played-tracks ()
  "Delete all played tracks from the Bongo playlist."
  (interactive)
  (with-bongo-playlist-buffer
    (let ((inhibit-read-only t)
          (line-move-ignore-invisible nil))
      (save-excursion
        (goto-char (point-min))
        (bongo-ignore-movement-errors
          (while (bongo-snap-to-object-line)
            (if (or (not (bongo-played-track-line-p))
                    (bongo-currently-playing-track-line-p))
                (bongo-next-object-line)
              (bongo-delete-line))))
        (bongo-delete-empty-sections)))))

(defun bongo-erase-buffer ()
  "Delete the entire contents of the current Bongo buffer.
However, if some track is currently playing, do not delete that."
  (interactive)
  (let ((inhibit-read-only t)
        (currently-playing-track
         (and (bongo-playing-p)
              (bongo-line-string
               (bongo-point-at-current-track-line)))))
    (erase-buffer)
    (when currently-playing-track
      (remove-text-properties 0 (length currently-playing-track)
                              '(bongo-external-fields nil)
                              currently-playing-track)
      (insert currently-playing-track))
    (goto-char (point-max))))

(defun bongo-flush-playlist (&optional delete-all)
  "Delete all played tracks from the Bongo playlist.
With prefix argument DELETE-ALL, clear the entire playlist."
  (interactive "P")
  (with-bongo-playlist-buffer
    (if delete-all
        (when (or (not bongo-confirm-flush-playlist)
                  (y-or-n-p "Clear the entire playlist? "))
          (bongo-erase-buffer))
      (when (or (not bongo-confirm-flush-playlist)
                (y-or-n-p "Delete all played tracks from the playlist? "))
        (bongo-delete-played-tracks)))))

(defun bongo-rename-line (new-name &optional point)
  "Rename the file corresponding to the track at POINT to NEW-NAME.
This function uses `bongo-update-references-to-renamed-files'."
  (interactive
   (when (bongo-track-line-p)
     (list (read-from-minibuffer "Rename track to: "
                                 (bongo-line-file-name)))))
  (with-point-at-bongo-track point
    (let ((old-name (bongo-line-file-name)))
      (rename-file old-name new-name)
      (if (or (and (eq bongo-update-references-to-renamed-files 'ask)
                   (y-or-n-p
                    (concat "Search all Bongo buffers and update "
                            "references to the renamed file? ")))
              bongo-update-references-to-renamed-files)
          (dolist (buffer (buffer-list))
            (when (bongo-buffer-p buffer)
              (set-buffer buffer)
              (goto-char (point-min))
              (bongo-ignore-movement-errors
                (while (bongo-snap-to-object-line)
                  (when (string-equal (bongo-line-file-name) old-name)
                    (bongo-delete-line)
                    (bongo-insert-line 'bongo-file-name new-name))
                  (bongo-next-object-line)))))
        (bongo-delete-line)
        (bongo-insert-line 'bongo-file-name new-name)))))

(defun bongo-dired-line (&optional point)
  "Open a Dired buffer containing the track at POINT."
  (interactive)
  (save-excursion
    (bongo-goto-point point)
    (bongo-snap-to-object-line)
    (dired (file-name-directory
            (save-excursion
              (while (bongo-header-line-p)
                (bongo-down-section))
              (bongo-line-file-name))))))


;;;; Serializing buffers

;;; (defun bongo-parse-header ()
;;;   "Parse a Bongo header.
;;; Leave point immediately after the header."
;;;   (let (pairs)
;;;     (while (looking-at "\\([a-zA-Z-]+\\): \\(.*\\)")
;;;       (setq pairs (cons (cons (intern (downcase (match-string 1)))
;;;                               (match-string 2))
;;;                         pairs))
;;;       (forward-line))
;;;     pairs))

(defvar bongo-library-magic-string
  "Content-Type: application/x-bongo-library\n"
  "The string that identifies serialized Bongo library buffers.
This string will inserted when serializing library buffers.")

(defvar bongo-playlist-magic-string
  "Content-Type: application/x-bongo-playlist\n"
  "The string that identifies serialized Bongo playlist buffers.
This string will inserted when serializing playlist buffers.")

(defvar bongo-magic-regexp
  "Content-Type: application/x-bongo\\(-library\\|-playlist\\)?\n"
  "Regexp that matches at the start of serialized Bongo buffers.
Any file whose beginning matches this regexp will be assumed to
be a serialized Bongo buffer.")

(add-to-list 'auto-mode-alist
             '("\\.bongo\\(-library\\)?$" . bongo-library-mode))
(add-to-list 'auto-mode-alist
             '("\\.bongo-playlist$" . bongo-playlist-mode))

(add-to-list 'format-alist
             (list 'bongo "Serialized Bongo library buffer"
                   bongo-library-magic-string 'bongo-decode
                   'bongo-encode t nil))
(add-to-list 'format-alist
             (list 'bongo "Serialized Bongo playlist buffer"
                   bongo-playlist-magic-string 'bongo-decode
                   'bongo-encode t nil))

(defun bongo-decode (beg end)
  "Convert a serialized Bongo buffer into the real thing.
Modify region between BEG and END; return the new end of the region.

This function is used when loading Bongo buffers from files.
You probably do not want to call this function directly;
instead, use high-level functions such as `find-file'."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (unless (looking-at bongo-magic-regexp)
        (error "Unrecognized format"))
      (bongo-delete-line)
      (while (not (eobp))
        (let ((start (point)))
          (condition-case nil
              (let ((object (read (current-buffer))))
                (delete-region start (point))
                (if (stringp object) (insert object)
                  (error "Unexpected object: %s" object)))
            (end-of-file
             (delete-region start (point-max))))))
      (point-max))))

(defvar bongo-line-serializable-properties
  (list 'bongo-file-name 'bongo-fields 'bongo-external-fields
        'bongo-header 'bongo-collapsed)
  "List of serializable text properties used in Bongo buffers.
When a bongo Buffer is written to a file, only serializable text
properties are saved; all other text properties are discarded.")

(defun bongo-encode (beg end buffer)
  "Serialize part of BUFFER into a flat representation.
Modify region between BEG and END; return the new end of the region.

This function is used when writing Bongo buffers to files.
You probably do not want to call this function directly;
instead, use high-level functions such as `save-buffer'."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (bongo-ensure-final-newline)
      (goto-char (point-min))
      (insert (if (bongo-playlist-buffer-p)
                  bongo-playlist-magic-string
                bongo-library-magic-string) "\n")
      (while (not (eobp))
        (bongo-keep-text-properties (point-at-bol) (point-at-eol)
                                    '(face mouse-face display follow-link))
        (bongo-keep-text-properties (point-at-eol) (1+ (point-at-eol))
                                    bongo-line-serializable-properties)
        (prin1 (bongo-extract-line) (current-buffer))
        (insert "\n")))))


;;;; Typical user entry points

(defvar bongo-mode-hook nil
  "Hook run when entering Bongo mode.")

(defvar bongo-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "\C-m" 'bongo-dwim)
    (define-key map [mouse-2] 'bongo-mouse-dwim)
    (define-key map "q" 'bongo-quit)
    (define-key map "Q" 'bury-buffer)
    (define-key map "g" 'bongo-redisplay)
    (define-key map "h" 'bongo-switch-buffers)
    (define-key map "l" 'bongo-recenter)
    (define-key map "\C-i" 'bongo-toggle-collapsed)
    (define-key map "p" 'previous-line)
    (define-key map "n" 'next-line)
    (substitute-key-definition
     'backward-paragraph 'bongo-previous-header-line map global-map)
    (substitute-key-definition
     'forward-paragraph 'bongo-next-header-line map global-map)
    (define-key map "\M-p" 'bongo-previous-header-line)
    (define-key map "\M-n" 'bongo-next-header-line)
    (define-key map "c" 'bongo-copy-line-as-kill)
    (define-key map "k" 'bongo-kill-line)
    (substitute-key-definition
     'kill-line 'bongo-kill-line map global-map)
    (define-key map "w" 'bongo-kill-region)
    (substitute-key-definition
     'kill-region 'bongo-kill-region map global-map)
    (define-key map "y" 'bongo-yank)
    (substitute-key-definition
     'yank 'bongo-yank map global-map)
    (substitute-key-definition
     'yank-pop 'bongo-yank-pop map global-map)
    (substitute-key-definition
     'undo 'bongo-undo map global-map)
    (define-key map " " 'bongo-pause/resume)
    (define-key map "\C-c\C-a" 'bongo-replay-current)
    (define-key map "\C-c\C-i" 'bongo-perform-next-action)
    (define-key map "\C-c\C-p" 'bongo-play-previous)
    (define-key map "\C-c\C-n" 'bongo-play-next)
    (define-key map "\C-c\C-r" 'bongo-play-random)
    (define-key map "\C-c\C-s" 'bongo-start/stop)
    (define-key map "s" 'bongo-seek)
    (define-key map "if" 'bongo-insert-file)
    (define-key map "id" 'bongo-insert-directory)
    (define-key map "it" 'bongo-insert-directory-tree)
    (define-key map "iu" 'bongo-insert-uri)
    (define-key map "e" 'bongo-append-enqueue)
    (define-key map "E" 'bongo-insert-enqueue)
    (define-key map "t" 'bongo-transpose-forward)
    (define-key map "T" 'bongo-transpose-backward)
    (define-key map "f" 'bongo-flush-playlist)
    (define-key map "r" 'bongo-rename-line)
    (define-key map "d" 'bongo-dired-line)
    (when (require 'volume nil t)
      (define-key map "v" 'volume))
    (let ((menu-map (make-sparse-keymap "Bongo")))
      (define-key menu-map [bongo-quit]
        '("Quit Bongo" . bongo-quit))
      (define-key menu-map [bongo-menu-separator-6]
        '("----" . nil))
      (define-key menu-map [bongo-customize]
        '("Customize Bongo..." . (lambda ()
                                   (interactive)
                                   (customize-group 'bongo))))
      (define-key menu-map [bongo-menu-separator-5]
        '("----" . nil))
      (define-key menu-map [bongo-flush-playlist]
        '("Flush Playlist" . bongo-flush-playlist))
      (define-key menu-map [bongo-insert-directory-tree]
        '("Insert Directory Tree..." . bongo-insert-directory-tree))
      (define-key menu-map [bongo-insert-directory]
        '("Insert Directory..." . bongo-insert-directory))
      (define-key menu-map [bongo-insert-file]
        '("Insert File..." . bongo-insert-file))
      (define-key menu-map [bongo-menu-separator-4]
        '("----" . nil))
      (define-key menu-map [bongo-start]
        '("Start Playback" . bongo-start))
      (define-key menu-map [bongo-play-previous-track]
        '("Play Previous Track" . bongo-play-previous))
      (define-key menu-map [bongo-play-next-track]
        '("Play Next Track" . bongo-play-next))
      (define-key menu-map [bongo-play-random-track]
        '("Play Random Track" . bongo-play-random))
      (define-key menu-map [bongo-replay-current-track]
        '("Replay Current Track" . bongo-replay-current))
      (define-key menu-map [bongo-menu-separator-3]
        '("----" . nil))
      (when (require 'volume nil t)
        (define-key menu-map [bongo-change-volume]
          '("Change Volume..." . volume)))
      (define-key menu-map [bongo-stop]
        '(menu-item "Stop Playback" bongo-stop
                    :enable (bongo-playing-p)))
      (define-key menu-map [bongo-seek-backward]
        '(menu-item "Seek Backward" bongo-seek-backward
                    :enable (bongo-seeking-supported-p)))
      (define-key menu-map [bongo-seek-forward]
        '(menu-item "Seek Forward" bongo-seek-forward
                    :enable (bongo-seeking-supported-p)))
      (define-key menu-map [bongo-pause/resume]
        '(menu-item "Pause Playback" bongo-pause/resume
                    :enable (bongo-pausing-supported-p)
                    :button (:toggle . (bongo-paused-p))))
      (define-key menu-map [bongo-menu-separator-2]
        '("----" . nil))
      (define-key menu-map [bongo-rename-track-file]
        '("Rename Track File..." . bongo-rename-line))
      (define-key menu-map [bongo-kill-track]
        '("Cut Track" . bongo-kill-line))
      (define-key menu-map [bongo-copy-track]
        '("Copy Track" . bongo-copy-line-as-kill))
      (define-key menu-map [bongo-insert-enqueue]
        '("Enqueue Track(s) Urgently" . bongo-insert-enqueue))
      (define-key menu-map [bongo-append-enqueue]
        '("Enqueue Track(s)" . bongo-append-enqueue))
      (define-key menu-map [bongo-play-track]
        '("Play Track" . bongo-play-line))
      (define-key menu-map [bongo-selected-track]
        '(menu-item "Selected Track"))
      (define-key menu-map [bongo-menu-separator-1]
        '("----" . nil))
      (define-key menu-map [bongo-switch-to-library]
        '(menu-item "Switch to Library" bongo-switch-buffers
                    :visible (bongo-playlist-buffer-p)))
      (define-key menu-map [bongo-switch-to-playlist]
        '(menu-item "Switch to Playlist" bongo-switch-buffers
                    :visible (bongo-library-buffer-p)))
      (define-key map [menu-bar bongo]
        (cons "Bongo" menu-map)))
    map)
  "Keymap used in Bongo mode buffers.")

(defun bongo-mode ()
  "Common parent major mode for Bongo buffers.
Do not use this mode directly.  Instead, use Bongo Playlist mode (see
`bongo-playlist-mode') or Bongo Library mode (see `bongo-library-mode').

\\{bongo-mode-map}"
  (kill-all-local-variables)
  (set (make-local-variable 'forward-sexp-function)
       'bongo-forward-section)
  (use-local-map bongo-mode-map)
  (setq buffer-read-only t)
  (setq major-mode 'bongo-mode)
  (setq mode-name "Bongo")
  (setq buffer-file-format '(bongo))
  (when bongo-default-directory
    (setq default-directory bongo-default-directory))
  (when bongo-dnd-support
    (bongo-enable-dnd-support))
  (run-mode-hooks 'bongo-mode-hook))

(define-derived-mode bongo-library-mode bongo-mode "Library"
  "Major mode for Bongo library buffers.
Contrary to playlist buffers, library buffers cannot directly
play tracks.  Instead, they are used to insert tracks into
playlist buffers.

\\{bongo-library-mode-map}"
    :group 'bongo :syntax-table nil :abbrev-table nil)

(define-derived-mode bongo-playlist-mode bongo-mode "Playlist"
  "Major mode for Bongo playlist buffers.
Playlist buffers are the most important elements of Bongo,
as they have the ability to play tracks.

\\{bongo-playlist-mode-map}"
  :group 'bongo :syntax-table nil :abbrev-table nil
  (setq bongo-stopped-track-marker (make-marker))
  (setq bongo-playing-track-marker (make-marker))
  (setq bongo-paused-track-marker (make-marker))
  (setq bongo-current-track-marker bongo-stopped-track-marker)
  (when window-system
    (setq left-fringe-width
          (* 2 (aref (font-info (face-font 'fringe)) 2))))
  (setq bongo-queued-track-marker (make-marker))
  (setq bongo-queued-track-arrow-marker (make-marker))
  (add-to-list 'overlay-arrow-variable-list
    'bongo-stopped-track-marker)
  (add-to-list 'overlay-arrow-variable-list
    'bongo-playing-track-marker)
  (add-to-list 'overlay-arrow-variable-list
    'bongo-paused-track-marker)
  (add-to-list 'overlay-arrow-variable-list
    'bongo-queued-track-arrow-marker))

(defvar bongo-library-buffer nil
  "The default Bongo library buffer, or nil.
Bongo library commands will operate on this buffer when
executed from buffers that are not in Bongo Library mode.

This variable overrides `bongo-default-library-buffer-name'.
See the function `bongo-library-buffer'.")

(defvar bongo-playlist-buffer nil
  "The default Bongo playlist buffer, or nil.
Bongo playlist commands will operate on this buffer when
executed from buffers that are not in Bongo Playlist mode.

This variable overrides `bongo-default-playlist-buffer-name'.
See the function `bongo-playlist-buffer'.")

(defun bongo-buffer-p (&optional buffer)
  "Return non-nil if BUFFER is in Bongo mode.
If BUFFER is nil, test the current buffer instead."
  (with-current-buffer (or buffer (current-buffer))
    (or (eq 'bongo-playlist-mode major-mode)
        (eq 'bongo-library-mode major-mode))))

(defun bongo-library-buffer-p (&optional buffer)
  "Return non-nil if BUFFER is in Bongo Library mode.
If BUFFER is nil, test the current buffer instead."
  (with-current-buffer (or buffer (current-buffer))
    (eq 'bongo-library-mode major-mode)))

(defun bongo-playlist-buffer-p (&optional buffer)
  "Return non-nil if BUFFER is in Bongo Playlist mode.
If BUFFER is nil, test the current buffer instead."
  (with-current-buffer (or buffer (current-buffer))
    (eq 'bongo-playlist-mode major-mode)))

(defun bongo-embolden-quoted-substrings (string)
  "Embolden each quoted `SUBSTRING' in STRING."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (while (re-search-forward "\\(`\\)\\(.*?\\)\\('\\)" nil 'noerror)
      (replace-match (concat (match-string 1)
                             (bongo-facify (match-string 2) 'bold)
                             (match-string 3))))
    (buffer-string)))

(defvar bongo-logo
  (find-image
   (list (list :type 'pbm :file "bongo-logo.pbm"
               :foreground (face-foreground 'bongo-comment nil t)
               :background (face-background 'bongo-comment nil t)))))

(defun bongo-insert-enabled-backends-comment ()
  (bongo-insert-comment "\
  Bongo is free software licensed under the GNU GPL.
  Report bugs to Daniel Brockman <daniel@brockman.se>.\n\n")
  (if bongo-enabled-backends
      (bongo-insert-comment
       (format
        "  Enabled backends: %s\n\n"
        (mapconcat
         (lambda (backend-name)
           (bongo-facify
            (bongo-backend-pretty-name backend-name) 'bold))
         bongo-enabled-backends ", ")))
    (bongo-insert-warning "\
  Warning:  No backends are enabled.  You will not be able to
            insert tracks or play anything.  Please customize
            the variable `bongo-enabled-backends'.  Then kill
            this buffer and restart Bongo.\n\n")
    (when (fboundp 'help-xref-button)
      (let ((inhibit-read-only t))
        (save-excursion
          (search-backward "customize")
          (replace-match (bongo-facify (match-string 0)
                                       'underline))
          (help-xref-button 0 'help-customize-variable
                            'bongo-enabled-backends))))))

(defun bongo-default-library-buffer ()
  (or (get-buffer bongo-default-library-buffer-name)
      (let ((buffer (get-buffer-create bongo-default-library-buffer-name)))
        (prog1 buffer
          (with-current-buffer buffer
            (bongo-library-mode)
            (when (and window-system bongo-logo)
              (let ((inhibit-read-only t))
                (insert "\n  ")
                (insert-image bongo-logo "[Bongo logo]")
                (insert "\n")))
            (when bongo-prefer-library-buffers
              (bongo-insert-comment "
  Welcome to Bongo, the buffer-oriented media player!\n"))
            (bongo-insert-comment
             (bongo-embolden-quoted-substrings "
  This is a Bongo library buffer.  It's empty now, but in a
  few moments it could hold your entire media collection ---
  or just the parts that you are currently interested in.

  To insert a single local media file, use `i f'.
  To insert a whole directory tree, use `i t'.
  To insert the URL of a media file or stream, use `i u'.

  To enqueue tracks in the playlist buffer, use `e'.
  To hop to the nearest playlist buffer, use `h'.\n\n"))
            (when bongo-prefer-library-buffers
              (bongo-insert-enabled-backends-comment)))))))

(defun bongo-default-playlist-buffer ()
  (or (get-buffer bongo-default-playlist-buffer-name)
      (let ((buffer (get-buffer-create bongo-default-playlist-buffer-name)))
        (prog1 buffer
          (with-current-buffer buffer
            (bongo-playlist-mode)
            (when (and window-system bongo-logo)
              (let ((inhibit-read-only t))
                (insert "\n  ")
                (insert-image bongo-logo "[Bongo logo]")
                (insert "\n")))
            (when (not bongo-prefer-library-buffers)
              (bongo-insert-comment "
  Welcome to Bongo, the buffer-oriented media player!\n"))
            (bongo-insert-comment
             (bongo-embolden-quoted-substrings "
  This is a Bongo playlist buffer.  It holds things that are
  about to be played, and things that have already been played.

  To start playing a track, use `RET'; to stop, use `C-c C-s'.
  To play the previous or next track, use `C-c C-p' or `C-c C-n'.
  To pause or resume, use `SPC', and to seek, use `s'.

  You can use `i f', `i t' and `i u' to insert things directly
  into playlist buffers, but enqueuing (using `e') from library
  buffers is often more convenient.  Use `h' to hop to one.\n\n"))
            (when (not bongo-prefer-library-buffers)
              (bongo-insert-enabled-backends-comment)))))))

(defun bongo-buffer ()
  "Return an interesting Bongo buffer, creating it if necessary.

First try to find an existing Bongo buffer, using a strategy similar to the
function `bongo-library-buffer' and the function `bongo-playlist-buffer'.
If no Bongo buffer is found, create a new one.
This function respects the value of `bongo-prefer-library-buffers'."
  (or (if bongo-prefer-library-buffers
          (or bongo-library-buffer
              bongo-playlist-buffer)
        (or bongo-playlist-buffer
            bongo-library-buffer))
      (let (result (list (buffer-list)))
        (while (and list (not result))
          (when (bongo-buffer-p (car list))
            (setq result (car list)))
          (setq list (cdr list)))
        result)
      (if bongo-prefer-library-buffers
          (bongo-default-library-buffer)
        (bongo-default-playlist-buffer))))

(defun bongo-playlist-buffer ()
  "Return a Bongo playlist buffer.

If the variable `bongo-playlist-buffer' is non-nil, return that.
Otherwise, return the most recently selected Bongo playlist buffer.
If there is no buffer in Bongo Playlist mode, create one.  The name of
the new buffer will be the value of `bongo-default-playlist-buffer-name'."
  (or bongo-playlist-buffer
      (let (result (list (buffer-list)))
        (while (and list (not result))
          (when (bongo-playlist-buffer-p (car list))
            (setq result (car list)))
          (setq list (cdr list)))
        result)
      (bongo-default-playlist-buffer)))

(defun bongo-library-buffer ()
  "Return a Bongo library buffer.

If the variable `bongo-library-buffer' is non-nil, return that.
Otherwise, return the most recently selected Bongo library buffer.
If there is no buffer in Bongo Library mode, create one.  The name of
the new buffer will be the value of `bongo-default-library-buffer-name'."
  (or bongo-library-buffer
      (let (result (list (buffer-list)))
        (while (and list (not result))
          (when (bongo-library-buffer-p (car list))
            (setq result (car list)))
          (setq list (cdr list)))
        result)
      (bongo-default-library-buffer)))

(defun bongo-playlist ()
  "Switch to a Bongo playlist buffer.
See the function `bongo-playlist-buffer'."
  (interactive)
  (switch-to-buffer (bongo-playlist-buffer)))

(defun bongo-library ()
  "Switch to a Bongo library buffer.
See the function `bongo-library-buffer'."
  (interactive)
  (switch-to-buffer (bongo-library-buffer)))

(defvar bongo-stored-window-configuration nil
  "This is used by `bongo' and `bongo-quit'.")

(defun bongo-quit ()
  "Quit Bongo by selecting another buffer.
In addition, delete all windows except one.

This function stores the current window configuration in
`bongo-stored-window-configuration', which is used by \\[bongo]."
  (interactive)
  (setq bongo-stored-window-configuration
        (current-window-configuration))
  (delete-other-windows)
  (let ((buffer (current-buffer)) (count 0))
    (while (and (bongo-buffer-p buffer) (< count 10))
      (setq buffer (other-buffer buffer) count (+ count 1)))
    (switch-to-buffer buffer)))

(defun bongo-switch-buffers (&optional other-window)
  "Switch from a Bongo playlist to a Bongo library, or vice versa.
If prefix argument OTHER-WINDOW is non-nil, display the other buffer
in another window."
  (interactive "P")
  (with-bongo-buffer
    (let* ((buffer (if (bongo-library-buffer-p)
                       (bongo-playlist-buffer)
                    (bongo-library-buffer)))
           (window (get-buffer-window buffer)))
      (if window
          (select-window window)
        (if other-window
            (pop-to-buffer buffer)
          (switch-to-buffer buffer))))))

(defun bongo ()
  "Switch to a Bongo buffer.
See the function `bongo-buffer'."
  (interactive)
  (when bongo-stored-window-configuration
    (set-window-configuration bongo-stored-window-configuration))
  (unless (bongo-buffer-p)
    (switch-to-buffer (bongo-buffer))))

(custom-reevaluate-setting 'bongo-header-line-mode)
(custom-reevaluate-setting 'bongo-mode-line-indicator-mode)
(custom-reevaluate-setting 'bongo-global-lastfm-mode)

;; For backwards compatibility.
(provide 'bongo-lastfm)

;;; Local Variables:
;;; coding: utf-8
;;; time-stamp-format: "%:b %:d, %:y"
;;; time-stamp-start: ";; Updated: "
;;; time-stamp-end: "$"
;;; time-stamp-line-limit: 20
;;; End:

(provide 'bongo)
;;; bongo.el ends here.
