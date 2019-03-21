;;; nix-haskell.el -- haskell-mode integrations for Nix -*- lexical-binding: t -*-

;; Author: Matthew Bauer <mjbauer95@gmail.com>
;; Homepage: https://github.com/NixOS/nix-mode
;; Keywords: nix

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;;; Code:

(require 'nix)
(require 'nix-instantiate)
(require 'nix-store)
(require 'haskell)
(require 'flycheck)
;; (require 'projectile)

(defvar nix-haskell-pkg-db-expr "{ pkgs ? import <nixpkgs> {}
, filename, packageName }: let
  inherit (pkgs) lib;
  getGhc = name: let compilerName = lib.replaceStrings [\".\" \"-\"] [\"\" \"\"] name;
                     getChannel = channel: import (builtins.fetchTarball \"channel:${channel}\") {};
                     findNonNull = l: r: if l != null then l
                                         else if (r.haskell.compiler ? ${compilerName})
                                              then r.haskell.compiler.${compilerName}
                                         else null;
                     compiler = builtins.foldl' findNonNull null (map getChannel [\"nixos-18.09\"]);
                 in pkgs.haskell.compiler.${compilerName} or (if compiler != null then compiler
                                                              else throw \"Can’t find compiler for ${compilerName}\");
  buildPkgDb = pkg: pkgs.buildEnv {
    name = \"package-db-${pkg.compiler.name}\";
    paths = [ (getGhc pkg.compiler.name) ] ++
            lib.closePropagation (pkg.getBuildInputs.haskellBuildInputs or (pkg.buildInputs ++ pkg.propagatedBuildInputs ++ pkg.nativeBuildInputs));
    pathsToLink = [ \"/lib/${pkg.compiler.name}/package.conf.d\" \"/bin\" ];
    buildInputs = [ (getGhc pkg.compiler.name) ];
    postBuild = ''
      ghc-pkg --package-db=$out/lib/${pkg.compiler.name}/package.conf.d recache
      if ! [ -x $out/bin/cabal ]; then
        ln -s ${pkgs.cabal-install}/bin/cabal $out/bin/cabal
      fi
    '';
    ignoreCollisions = true;
  };
  pkg = if lib.hasSuffix \".cabal\" filename
        then pkgs.haskellPackages.callCabal2nix \"auto-callcabal2nix\" (builtins.toPath filename)
        else if lib.hasSuffix \".nix\" filename
        then (let nixExpr = import filename;
                  nixExpr' = if builtins.isFunction nixExpr then nixExpr {} else nixExpr;
              in (if nixExpr' ? compiler then nixExpr'
                  else if builtins.isAttrs nixExpr'
                  then let nixExpr'' = if nixExpr' ? haskellPackages then nixExpr'.haskellPackages
                                       else if nixExpr' ? haskellPackageSets then nixExpr'.haskellPackageSets.ghc
                                       else nixExpr';
                       in (if nixExpr'' ? ${packageName} then nixExpr''.${packageName}
                           else throw \"Can't find target for ${packageName} in ${filename}.\")
                  else throw \"Can't import ${filename} correctly.\"))
        else throw \"Can't do anything with ${filename}.\";
in buildPkgDb pkg")

(defvar nix-haskell--running-processes nil)
(defvar nix-haskell--package-db-cache nil)

(defun nix-haskell--store-sentinel (err buf drv-file drv proc event)
  "Make a nix-haskell process.
ERR the error buffer.
BUF the main buffer.
DRV-FILE filename of derivation.
DRV parsed derivation file.
PROC the process that has been run.
EVENT the event that was fired."
  (pcase event
    ("finished\n"
     (nix-haskell--interactive buf drv-file drv)
     (kill-buffer err))
    (_ (display-buffer err)))
  (unless (process-live-p proc)
    (kill-buffer (process-buffer proc))))

(defun nix-haskell--instantiate-sentinel (prop err proc event)
  "Make a nix-haskell process.
PROP the prop name of nix-haskell--running-processes.
ERR the error buffer.
PROC the process that has been run.
EVENT the event that was fired."
  (pcase event
    ("finished\n"
     (with-current-buffer (process-buffer proc)
       (unless (eq (buffer-size) 0)
	 (let* ((drv-file (substring (buffer-string) 0 (- (buffer-size) 1)))
		(drv (nix-instantiate--parsed drv-file))
		(out (cdadr (cadar drv))))
	   (dolist
	       (callback (lax-plist-get nix-haskell--running-processes prop))
	     (funcall callback out drv-file))
	   (setq nix-haskell--package-db-cache
		 (lax-plist-put nix-haskell--package-db-cache
				prop (list out drv-file))))))
     (setq nix-haskell--running-processes
	   (lax-plist-put nix-haskell--running-processes prop nil))
     (kill-buffer err))
    (_ (display-buffer err)))
  (unless (process-live-p proc)
    (kill-buffer (process-buffer proc))))

(defun nix-haskell--get-pkg-db (callback)
  "Get a package-db async.
CALLBACK called once the package-db is determined."
  (let ((cabal-file (haskell-cabal-find-file default-directory))
	filename package-name root)

    ;; (when (and (projectile-project-p) (not root)
    ;;	       (or (file-exists-p (expand-file-name "default.nix" (projectile-project-root)))
    ;;		   (file-exists-p (expand-file-name "shell.nix" (projectile-project-root)))))
    ;;   (setq root (projectile-project-root)))
    (unless root
      (setq root (locate-dominating-file default-directory "default.nix")))
    (unless root
      (setq root (locate-dominating-file default-directory "shell.nix")))
    (when root
      (setq root (expand-file-name root)))

    (when cabal-file (setq cabal-file (expand-file-name cabal-file)))
    (unless cabal-file (error "Cannot find a valid .cabal file"))
    (setq package-name (replace-regexp-in-string ".cabal$" "" (file-name-nondirectory cabal-file)))

    (unless (and filename (file-exists-p filename))
      (setq filename (expand-file-name "default.nix" root)))
    (unless (and filename (file-exists-p filename))
      (setq filename (expand-file-name "shell.nix" root)))
    (unless (and filename (file-exists-p filename))
      (setq filename cabal-file))

    ;; TODO: update cache after certain threshold
    (let ((cache (lax-plist-get nix-haskell--package-db-cache cabal-file)))
      (if cache (apply callback cache)
	(let* ((data (lax-plist-get nix-haskell--running-processes cabal-file))
	       (stdout (generate-new-buffer "*nix-haskell-instantiate-stdout*"))
	       (stderr (generate-new-buffer "*nix-haskell-instantiate-error*")))
	  (setq nix-haskell--running-processes
		(lax-plist-put nix-haskell--running-processes
			       cabal-file (cons callback data)))
	  (make-process
	   :name (format "*nix-haskell*<%s>" cabal-file)
	   :buffer stdout
	   :command (list nix-instantiate-executable
			  "-E" nix-haskell-pkg-db-expr
			  "--argstr" "filename" filename
			  "--argstr" "packageName" package-name)
	   :noquery t
	   :sentinel (apply-partially 'nix-haskell--instantiate-sentinel
				       cabal-file stderr)
	   :stderr stderr)))))
  t)

(defun nix-haskell--interactive (buf out drv)
  "Setup interactive buffers for nix-haskell.

Handles flycheck and haskell-interactive modes currently.

BUF the buffer this was called from.
OUT filename of derivation.
DRV derivation file."
  (if (file-exists-p out)
      (let ((package-db out))
	(with-current-buffer buf
	  ;; Find package db directory.
	  (setq package-db (expand-file-name "lib" package-db))
	  (setq package-db (expand-file-name
			    (car (directory-files package-db nil "^ghc"))
			    package-db))
	  (setq package-db (expand-file-name "package.conf.d" package-db))

	  (setq-local haskell-compile-cabal-build-command
		      (format "%s new-build" (expand-file-name "bin/cabal" out)))

	  ;; Setup haskell-mode args.
	  (setq-local haskell-process-type 'cabal-new-repl)
	  (setq-local haskell-process-path-cabal (expand-file-name "bin/cabal" out))
	  (make-local-variable 'haskell-process-args-cabal-new-repl)
	  (add-to-list 'haskell-process-args-cabal-new-repl
			(format "--with-ghc-pkg=%s/bin/ghc-pkg" out) t)
	  (add-to-list 'haskell-process-args-cabal-new-repl
			(format "--with-ghc=%s/bin/ghc" out) t)
	  (add-to-list 'haskell-process-args-cabal-new-repl
			(format "--ghc-pkg-option=--package-db=%s" package-db) t)
	  (add-to-list 'haskell-process-args-cabal-new-repl
			(format "--ghc-option=-package-db=%s" package-db) t)
	  (interactive-haskell-mode 1)

	  ;; Setup flycheck.
	  (setq-local flycheck-haskell-ghc-executable
		      (expand-file-name "bin/ghc" out))
	  (make-local-variable 'flycheck-ghc-package-databases)
	  (add-to-list 'flycheck-ghc-package-databases package-db)
	  (flycheck-mode 1)))
    (let ((stdout (generate-new-buffer "*nix-haskell-store-stdout*"))
	  (stderr (generate-new-buffer "*nix-haskell-store-stderr*")))
      (make-process
       :name (format "*nix-haskell-store*<%s>" drv)
       :buffer stdout
       :command (list nix-store-executable "-r" drv)
       :noquery t
       :sentinel (apply-partially 'nix-haskell--store-sentinel stderr buf out drv)
       :stderr stderr))))

(defun nix-haskell-setup ()
  "Hook to run to set up Haskell buffer for nix-haskell.

To use with use-package, something like this will work:

\(use-package nix-haskell
  :hook \(haskell-mode . nix-haskell-setup))"
  (nix-haskell--get-pkg-db (apply-partially 'nix-haskell--interactive
					    (current-buffer))))

(provide 'nix-haskell)
;;; nix-haskell.el ends here