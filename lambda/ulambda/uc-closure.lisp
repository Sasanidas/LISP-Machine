;-*- Mode:LISP; Readtable:ZL; Base:8; Fonts:(CPTFONT CPTFONTB) -*-
;;; Written by jrm

(defconst uc-closure '(

;;; Here is how lexical closures work
;;; A lexical closure consists of a piece of code and an environment to
;;; resolve free variable references.  The code is implemented by a FEF and the
;;; environment is implemented as a list of vectors.  Each car in the environment is
;;; a lexical environment frame which is a vector of variable bindings.  As there is
;;; no way to extend the number of variables in a lexical environment, a vector
;;; saves space, but more importantly, since the lexically visible variables can be
;;; known at compile time, the compiler can generate code that simply "arefs" a
;;; given frame and finds the correct value of a lexical variable.  A lexical
;;; environment is a list of these vectors.

;;; A closure is implemented like this:
;;;   (dtp-closure          )
;;;                      |
;;;                 /----/ pointer to closure
;;;                
;;;   (cdr-next dtp-fef-pointer   --)--- points to a fef containing the code
;;;   (cdr-nil  dtp-list            )
;;;                              |
;;;                 /------------/ pointer to lexical environment
;;;                
;;;   (cdr-normal dtp-list        --)--- points to lexical frame
;;;   (cdr-error  dtp-list        --)--- points to next environment

;;; Now for the nitty gritty details.
;;; When a stack frame is active (i.e. it is still on the stack and can be run.)  The
;;; variables which are bound in the frame live on the stack.  The lexical frame
;;; must contain pointers to the actual locations of the variables.  The lexical
;;; frames consist of a vector of pointers to the actual locations which are tagged
;;; with DTP-EXTERNAL-VALUE-CELL-POINTER (evcp).  When the stack frame is exited, the
;;; values of the variables are copied into the heap and all the evcp's to the stack
;;; are changed to point to the heap copy.

;;; Lexical contexts may be flattened.  This saves space and time in several areas.
;;; However, some lexical contexts cannot be flattened because this would cause
;;; sharing of variables that should be unshared.  The compiler can recognize this
;;; and create code that unshares certain shared variables.

;;; How a frame with closures is set up in the first place:

;Frame begins here     (dtp-fix) ;bits controlling return
;                      (dtp-fix)
;                 (DTP-FEF-POINTER   --)---> to code for the frame.
;Arguments        (cdr-next ......)
; cdr codes are   (cdr-next ......)
; set right               : <more args>
;                         :
; last arg        (cdr-nil  ......)
;Locals           (...............) <--- A-LOCALP if this is the current function
; random boxed    (...............)
; objects                 : <more locals>
;                         :
;Closure          (cdr-error dtp-locative  ---)---> to heap closures for purpose
; locatives               : <more locatives>        of disconnecting.
;                         :
; In the last two locals:
;Shared lexical frame    (dtp-list   ---)---> to the shared frame
;Unshared frame list     (dtp-list   ---)---> to unshared frame list

; The top of the stack is here.

;;; Notes on the above diagram.
;;; 1) The word just before the lexical frame is used
;;;    to locate the beginning of the stack
;;;    frame.
;;; 2) The lexical frame need not be there.  All the local slots
;;;    are set to point to nil when the frame is entered.  When it comes
;;;    time to make a stack closure, the next to last local slot is
;;;    checked to see if a lexical frame has been made.  If it has not,
;;;    (i.e. it is nil) the FEF is looked at to find a list of args and
;;;    locals to forward the slots in the lexical frame to.  If the list
;;;    in the FEF is nil, this means that the current frame is empty.
;;;    In this case, the next to last local is set to T indicating an
;;;    empty frame.
;;; 3) Note 3 is self referential.
;;; 4) A-LEXICAL-ENVIRONMENT will point to the context outside of this
;;;    frame so all closures created in this frame will contain a copy
;;;    of A-LEXICAL-ENVIRONMENT.

;CLOSURE-TRAP

;;; Stack closures cannot work.  They are not generated by the below code.

;     ;Closure trap is an efficiency hack to speed up downward funargs.  If
;     ;we take a closure trap, we mark the frame for copy out on popping, otherwise,
;     ;we know that there are no closures pointing to this frame and we can just
;     ;punt.

;     ;Save some regs.
;  ((pdl-push) m-t)
;  ((pdl-push) m-a)

;     ;Save the location and md.
;  ((pdl-push) vma)
;  ((pdl-push) md)

;     ;Read the lexical environment.  It is the cadr of the closure. (cdr coded)
;  ((vma-start-read) add md (a-constant 1))
;  (check-page-read)
;  (dispatch transport md)
;  ((m-t) q-typed-pointer md)

;     ;Now we cdr on down the lexical environment and mark each stack frame
;     ;that contains the variables used in the lexical environment.

;closure-trap-loop
;     ;Quit when we reach the end of the loop.
;  (jump-equal m-t a-v-nil closure-trap-store-closure)
;     ;M-A gets the lexical frame, M-T gets the next environment.
;  (call carcdr-no-sb)

;     ;Empty frames need no work done.
;  (jump-equal m-a a-v-true closure-trap-loop)

;     ;Otherwise, read the cell before the lexical frame.  It is either an evcp to the
;     ;frame FEF or something else.  If it is an evcp, we do some work.  If it is not,
;     ;we keep scanning on down.
;  ((vma-start-read) sub m-a (a-constant 1))
;  (check-page-read)
;  (dispatch transport-no-evcp md)
;  (check-data-type-jump-not-equal md m-tem dtp-external-value-cell-pointer
;                                 closure-trap-loop)

;     ;MD has the evcp to the fef.  The address field points to the beginning of the
;     ;stack frame.  Turn on the copy out bit if necessary.  If the bit is on, we don't
;     ;need to continue to trace back.

;  ((vma-start-read) add md (a-constant (eval %lp-entry-state)))
;  (check-page-read)
;  (dispatch transport md)
;     ;Check if bad data in the stack frame.
;  (check-data-type-call-not-equal md m-tem dtp-fix illop)
;     ;Note if the ens-environment-pointer bit is set, the attention bit is too, so we
;     ;can skip it.
;  (jump-if-bit-set (lisp-byte %%lp-ens-environment-pointer-points-here 1) md
;                  closure-trap-store-closure)
;  ((md-start-write) ior md
;                       (a-constant (byte-value
;                                     (lisp-byte %%lp-ens-environment-pointer-points-here) 1)))
;  (check-page-write) ;wrote a fixnum, no volatility test.

;     ;Turn on the attention bit if necessary.
;  ((vma-start-read) add vma
;                   (a-constant (difference (eval %lp-call-state) (eval %lp-entry-state))))
;  (check-page-read)
;  (dispatch transport md)
;  (check-data-type-call-not-equal md m-tem dtp-fix illop)
;  (jump-if-bit-set (lisp-byte %%lp-cls-attention) md closure-trap-loop)
;  ((md-start-write) ior md
;                        (a-constant (byte-value (lisp-byte %%lp-cls-attention) 1)))
;  (check-page-write) ;wrote a fixnum, no volatility.
;  (jump closure-trap-loop)

;closure-trap-store-closure
;     ;Write back a dtp-closure.
;  ((m-tem) (a-constant (eval dtp-closure)))
;  ((m-tem1) pdl-pop)
;  ((md) dpb m-tem q-data-type a-tem1)
;  ((vma-start-write) pdl-pop)
;  (check-page-write)
;  (gc-write-test)
;     ;Restore regs.
;  ((m-a) pdl-pop)
;  ((m-t) pdl-pop)
;  (popj)


(begin-pagable-ucode)
   (macro-ir-decode (qind1-a make-closure-top-level *))
MAKE-CLOSURE-TOP-LEVEL
  (jump-xct-next make-closure-1)
 ((pdl-push) a-v-nil)

   (macro-ir-decode (qind4-a make-closure *))
MAKE-CLOSURE
  ((pdl-push) a-lexical-environment)

make-closure-1

     ;The low 9 bits of the MAKE-CLOSURE instruction specify the local
     ;slot that holds the locative to the q in the closure that holds
     ;the lexical frame of the closure.  When we make a closure, we may
     ;have to set up the lexical frame, the dtp-list pointer to the top
     ;of the stack frame, the list of lexical frame copies and the
     ;pointer to the lexical frame itself.

     ;M-C gets the lexical-frame
  (call find-or-create-lexical-frame)
  ((pdl-push) m-c)

     ;Allocate 4 slots, 2 for the closure, 2 for the environment.
  ((m-b) (a-constant 4))
  (call-xct-next allocate-list-storage)
 ((m-s) dpb m-zero q-all-but-typed-pointer a-background-cons-area)

     ;Fill in the slots we allocated.  This is done in order of things on the
     ;stack and is pretty random.

     ;Put in the lexical frame.
  ((vma) add m-t (a-constant 2))
  ((md-start-write) dpb pdl-pop q-typed-pointer (a-constant (byte-value q-cdr-code cdr-normal)))
  (check-page-write)
  (gc-write-test)

     ;Put in the lexical environment tail.
  ((vma) add m-t (a-constant 3))
  ((md-start-write) dpb pdl-pop q-typed-pointer (a-constant (byte-value q-cdr-code cdr-error)))
  (check-page-write)
  (gc-write-test)

     ;Put in the FEF pointer.
  ((vma) m-t)
  ((md-start-write) dpb pdl-pop q-typed-pointer (a-constant (byte-value q-cdr-code cdr-next)))
  (check-page-write)
  (gc-write-test)

    ;Put in the environment pointer.
  ((vma) add m-t (a-constant 1))
  ((m-tem) add m-t (a-constant 2))
  ((md-start-write) dpb m-tem q-pointer (a-constant (plus (byte-value q-cdr-code cdr-nil)
                                                          (byte-value q-data-type dtp-list))))
  (check-page-write)
  (gc-write-test)


; The tail recursion flag doesn't work, so we don't need this code.
;     ;This code marks the frame so tail recursion will not flush it.
;     ;This is probably unnecessary, but the stack closure code has it
;     ;and we shouldn't just lose randomly.
;  ((pdl-buffer-index) add m-ap (a-constant (eval %lp-entry-state)))
;  ((m-2) c-pdl-buffer-index)
;  ((c-pdl-buffer-index) dpb m-minus-one (lisp-byte
;                                         %%lp-ens-unsafe-rest-arg) a-2)
     ;Locate the local slot to contain the locative.
  ((pdl-index) macro-ir-adr)
  ((pdl-index) add pdl-index a-localp)
     ;Put a locative there
  ((m-tem) add m-t (a-constant 2))
  ((c-pdl-buffer-index) dpb m-tem q-pointer
                        (a-constant
                          (plus (byte-value q-data-type dtp-locative)
                                (byte-value q-cdr-code cdr-error))))

     ;Turn on the trap for frame exit and the attention bit.
  ((pdl-index) add m-ap (a-constant (eval %lp-entry-state)))
  ((c-pdl-buffer-index) ior c-pdl-buffer-index
                        (a-constant (byte-value (lisp-byte %%lp-ens-environment-pointer-points-here) 1)))
  ((pdl-buffer-index) add m-ap (a-constant (eval %lp-call-state)))
  (popj-after-next
    (c-pdl-buffer-index) ior c-pdl-buffer-index (a-constant (byte-value (lisp-byte %%lp-cls-attention) 1)))
 ((pdl-push m-t) q-pointer m-t (a-constant (byte-value q-data-type dtp-closure)))



FIND-OR-CREATE-LEXICAL-FRAME
     ;This routine sets up the lexical frame.  If it is already set up,
     ;it just returns.  The lexical frame in either case will be in M-C.

  (call find-lexical-frame)

     ;If the slot is not nil, it is already set up.
  (popj-not-equal-xct-next c-pdl-buffer-index a-v-nil)
 ((m-c) c-pdl-buffer-index)

     ;The slot is nil, so we need to set it up.
     ;Get the FEF cell two before the instructions.  This is the lexical
     ;map.
  ((m-c) pdl-index) ;save for create lexical frame empty.
  ((vma-start-read) m-fef)
  (check-page-read) ;FEF is not in oldspace, so no transport here.
  ((m-1) (lisp-byte %%fefh-pc-in-words) md)
  ((m-1) m-a-1 m-1 (a-constant 1)) ;subtract 2
  ((vma-start-read) add m-fef a-1)   ;Read the location.
  (check-page-read)
  (dispatch transport md)

     ;Make vma point to the car of list.  Since the list guaranteed to
     ;be cdr coded, we can simply scan down it by bumping the vma
     ;instead of having to car and cdr.
  ((vma) q-typed-pointer md)

     ;NIL in the FEF means no lexical frame
  (jump-equal vma a-v-nil create-lexical-frame-empty)

     ;Calculate length of first lexical frame.  Save address of FEF map
     ;for later.
  (call-xct-next find-length-of-cdr-coded-list)
 ((pdl-push) vma)

     ;Allocate list storage takes boxed size untyped in M-B and area in
     ;M-S.  Returns address in M-T.
  ((pdl-push) q-pointer m-b)
;  ((m-b) add m-b (a-constant 1))
  (call-xct-next allocate-list-storage)
 ((m-s) dpb m-zero q-all-but-typed-pointer a-background-cons-area)

     ;Install new lexical frame in stack frame.
  (call find-lexical-frame)
;  ((m-tem) add m-t (a-constant 1))
  ((c-pdl-buffer-index) dpb m-t q-pointer (a-constant (byte-value q-data-type dtp-list)))

     ;M-B gets count minus one.
  ((m-b) sub pdl-pop (a-constant 1))
     ;M-K gets stuff to merge into lexical frame.
  (call-xct-next convert-pdl-buffer-address)
 ((m-k) m-ap)
  ((m-k) dpb m-k q-pointer
         (a-constant (plus (byte-value q-data-type
                                       dtp-external-value-cell-pointer)
                           (byte-value q-cdr-code cdr-next))))

;     ;Write the address of the FEF in the first lexical frame slot.
;  ((vma) m-t)
;  ((md-start-write m-k) dpb m-k q-pointer
;        (a-constant (plus (byte-value q-data-type
;                                      dtp-external-value-cell-pointer)
;                          (byte-value q-cdr-code cdr-next))))
;  (check-page-write)
;  (gc-write-test)

     ;Bump M-T back by one for the loop.
  ((m-t) sub m-t (a-constant 1))
     ;M-C gets offset of local block with respect to arg 0.
  ((m-c) a-localp)
  ((m-c) m-a-1 m-c a-ap)
     ;M-D gets address of one beyond the end of the FEF map.
  ((m-d) m+a+1 pdl-pop a-b)

find-or-create-lexical-frame-fill-frame
     ;Read from the FEF map.
  ((vma-start-read m-d) sub m-d (a-constant 1))
  (check-page-read)
  (dispatch transport md)
     ;If the fixnum in the FEF map has the sign bit set, it is a local.
     ;Anyway, only the low 10 bits are of interest.
  (jump-if-bit-clear-xct-next boxed-sign-bit md
                              find-or-create-lexical-frame-arg)
 ((m-1) (byte-field 10. 0) md)
  ((m-1) add m-1 a-c) ;Otherwise, it is a local: add the local offset

find-or-create-lexical-frame-arg
     ;Get the pointer into the new lexical frame, and write a cdr-next
     ;evcp to the appropriate spot.
  ((vma m-t) add m-t (a-constant 1))
  ((md-start-write) m+a+1 m-k a-1)
  (check-page-write)
  (gc-write-test)
     ;Loop if not done.
  (jump-not-equal-xct-next m-b a-zero find-or-create-lexical-frame-fill-frame)
 ((m-b) sub m-b (a-constant 1))

     ;Rewrite the last one to be cdr nil.
  ((md-start-write) dpb md q-typed-pointer
                           (a-constant (byte-value q-cdr-code cdr-nil)))
  (check-page-write) ;No gc-write test, we just changed the cdr code.

     ;Get the lexical frame in M-C.
  (call find-lexical-frame)
  (popj-after-next no-op)
 ((m-c) c-pdl-buffer-index)

create-lexical-frame-empty
     ;M-C and the slot in the frame just get A-V-TRUE.
  (popj-after-next
    (pdl-index) m-c)
 ((c-pdl-buffer-index m-c) a-v-true)



FIND-LEXICAL-FRAME
     ;It is one slot before the list of frame copies.
  (call find-list-of-lexical-frame-copies)
     ;pdl-index points to the list of frame copies.
  (popj-after-next no-op)
 ((pdl-index) sub pdl-index (a-constant 1))

FIND-LIST-OF-LEXICAL-FRAME-COPIES
     ;Looks at m-fef and makes pdl-index point to the location in the
     ;pdl buffer that holds the lexical frame copy list.

     ;Find the %fefhi-misc word
  ((vma-start-read) add m-fef (a-constant (eval %fefhi-misc)))
  (check-page-read)
     ;Extract the local block length.
  ((pdl-index) (lisp-byte %%fefhi-ms-local-block-length) md)
     ;Add it to the beginning of the locals, and subtract 1.
  (popj-after-next
    (pdl-index) add pdl-index a-localp)
 ((pdl-index) sub pdl-index (a-constant 1))



   (macro-ir-decode (qind4-a closure-disconnect-first *))
CLOSURE-DISCONNECT-FIRST
     ;In order to unshare lexical variables, we must have two copies
     ;of the lexical frame.  CLOSURE-DISCONNECT-FIRST copies the lexical
     ;frame and makes a closure use the copy instead of the original.
     ;The compiler will not issue this instruction if the lexical frame
     ;is T.
     ;; JRM 5-Feb-87 09:50:00
     ;; Boy did I lose, the compiler WILL issue this instruction if
     ;; the lexical frame is T.  I looked at it and it should surprise
     ;; no one that it is easier to repair the microcode than the compiler.

  (call find-lexical-frame)
  ((m-t) dpb c-pdl-buffer-index q-typed-pointer a-zero) ;flush cdr code
  (jump-equal m-t a-v-true closure-disconnect)

  (call unshare-lexical-frame)

   (macro-ir-decode (qind4-a closure-disconnect *))
CLOSURE-DISCONNECT
     ;Should be called with the new lexical frame in M-T.  The compiler
     ;only puts these instructions immediately after a previous
     ;closure-disconnect of closure-disconnect-first.  Therefore, we
     ;must leave the new environment in M-T.

     ;; If the compiler loses on closure-disconnect-first, there is no reason
     ;; to believe that it will win here.

     ;Find out which closure to disconnect.
  ((m-a) macro-ir-adr)
  ((pdl-index m-k) add m-a a-localp)

     ;If the closure is not set up, no need to disconnect.
  ((m-tem) q-typed-pointer c-pdl-buffer-index)
  (popj-equal m-tem a-v-nil)

     ;Otherwise, it is a locative to the pointer to the lexical frame to
     ;replace.
  (check-data-type-call-not-equal c-pdl-buffer-index m-tem dtp-locative
                                  illop)
     ;Indirect through the locative.
  ((vma-start-read) c-pdl-buffer-index)
  (check-page-read)
  (dispatch transport md)
     ;Smash pointer to old closure.
  ((pdl-index) m-k)
  ((c-pdl-buffer-index) a-v-nil)
     ;Put in pointer to lexical environment copy.
  ((md-start-write) selective-deposit md q-all-but-pointer a-t)
  (check-page-write)
  (gc-write-test)
  (popj)

UNSHARE-LEXICAL-FRAME
     ;Copy the lexical frame and put it on the list of lexical frame
     ;copies.  The new frame is in M-T.

     ;Find and copy the lexical frame.

  (call find-lexical-frame)
  (popj-equal c-pdl-buffer-index a-v-nil)
  (call-xct-next copy-cdr-coded-list)
 ((vma m-k) c-pdl-buffer-index)

     ;Save M-T (copy) for later
  ((pdl-push) m-t)
     ;Find list of frame copies, push M-T for qcons
  (call-xct-next find-list-of-lexical-frame-copies)
 ((pdl-push) m-t)

     ;Push frame list for qcons and cons up new list.
  ((pdl-push) c-pdl-buffer-index)
  (call-xct-next qcons)
 ((m-s) dpb m-zero q-all-but-typed-pointer a-background-cons-area)

     ;Point at list of copies.
  (call find-list-of-lexical-frame-copies)
     ;Smash with new cons, and return copy in M-T.
  (popj-after-next
    (c-pdl-buffer-index) m-t)
 ((m-t) pdl-pop)


COPY-CDR-CODED-LIST
     ;Returns a copy in M-T of the cdr coded list in VMA.

     ;VMA gets clobbered by call, so we must save it.  M-B gets set up
     ;by call, so nothing need be done.
  (call-xct-next find-length-of-cdr-coded-list)
 ((pdl-push) vma)

     ;Make some room for the copy.
  (call-xct-next allocate-list-storage)
 ((m-s) dpb m-zero q-all-but-typed-pointer a-background-cons-area)

     ;Set up for loop.  Save M-T to unclobber later.
     ;M-B has the count minus one.  M-S gets the source.  M-T gets the
     ;copy.
  ((m-b) sub m-b (a-constant 1))
  ((m-s) sub pdl-pop (a-constant 1))
  ((pdl-push m-t) sub m-t (a-constant 1))

copy-cdr-coded-list-loop
     ;Read the old value.  Use transport-no-evcp because this is primarily used
     ;for copying lexical frames which are full of evcps.  Using this funny
     ;transport causes them not to be snapped.
  ((vma-start-read m-s) add m-s (a-constant 1))
  (check-page-read)
  (dispatch transport-no-evcp md)
     ;Write it into the new location.
  ((vma-start-write m-t) add m-t (a-constant 1))
  (check-page-write)
  (gc-write-test)
     ;Loop until done.
  (jump-not-equal-xct-next m-b a-zero copy-cdr-coded-list-loop)
 ((m-b) sub m-b (a-constant 1))

     ;Result goes in M-T.
  (popj-after-next
    (m-t) add pdl-pop (a-constant 1))
 ((m-t) dpb m-t q-pointer (a-constant (byte-value q-data-type dtp-list)))


FIND-LENGTH-OF-CDR-CODED-LIST
     ;Calculates length of cdr coded list pointed to by vma.  Untyped
     ;result goes into M-B. Smashes M-TEM, VMA and MD.

     ;Prepare for the loop.
  ((m-b) (a-constant 1))
  ((vma) sub vma (a-constant 1))

find-length-of-cdr-coded-list-loop
     ;Read the next cell.  Use transport-no-evcp because this is primarily used
     ;for copying lexical frames which are full of evcps.  Using this funny
     ;transport causes them not to be snapped.
  ((vma-start-read) add vma (a-constant 1))
  (check-page-read)
  (dispatch transport-no-evcp md)
     ;If cdr-nil, return.
     ;If cdr-next, loop.
     ;Otherwise, error.
  ((m-tem) q-cdr-code md)
  (popj-equal m-tem (a-constant (eval cdr-nil)))
  (jump-equal-xct-next m-tem (a-constant (eval cdr-next))
                       find-length-of-cdr-coded-list-loop)
 ((m-b) add m-b (a-constant 1))
  (call illop) ;if cdr-error or cdr-normal



   (macro-ir-decode (qind4-b closure-unshare *))
CLOSURE-UNSHARE
     ;Unshare a local variable in all copies (made by
     ;CLOSURE-DISCONNECT) of this frame's lexical frame.  The address
     ;field of the instruction is a 9-bit number which is this
     ;variable's index in the lexical frame.  We do this as follows: It
     ;is assumed that we have made a copy of the stack-consed lexical
     ;frame and pushed it onto the list of lexical frame copies.  In the
     ;list of frame copies, the slots in the frame point with evcps to
     ;the locals and args of the frame.  In order to unshare a variable,
     ;we snap the evcp on the first frame in the list and then walk down
     ;the list and change the evcp's in their slots to point to the copy
     ;in the first slot.  If we find something already snapped in one of
     ;the lexical frames on the list, we do not want to share with it,
     ;so we quit.

     ; This instruction is never used in a frame whose lexical frame is
     ; T (empty).

     ;Find the list of copies, if it is nil, nothing to unshare.
  (call find-list-of-lexical-frame-copies)
  (popj-equal-xct-next c-pdl-buffer-index a-v-nil)
 ((m-t) c-pdl-buffer-index)

     ;M-B gets the number of the slot.
  ((m-b) macro-ir-adr)

     ;Read evcp from current lexical frame.
  ((pdl-index) sub pdl-index (a-constant 1))
  ((vma-start-read) add c-pdl-buffer-index a-b)
  (check-page-read)
  (dispatch transport-no-evcp md)

     ;M-K gets the evcp, M-C gets the value at the end of the evcp.
  (call-xct-next pdl-fetch)
 ((vma m-k) q-typed-pointer md)
; (check-page-read)
  (dispatch transport md)
  ((m-c) q-typed-pointer md)

     ;M-1 will hold flag telling if we have unshared once.
  ((M-1) M-ZERO)

closure-unshare-forward-to-copy
     ;M-K has an evcp -> the stack slot for the local we are unsharing.
     ;M-C has what to store in place of any evcps pointing to this
     ;local.  M-1 is zero if we have not yet found an evcp pointing to
     ;this local.  M-B has the index of this local's slot in the lexical
     ;frame, and in copies of it.  M-T has the list of all lexical frame
     ;copies made in this frame.  Examine each element of the list.
     ;Note that all the ones we need to unforward must be more recent
     ;than the ones we don't need to unforward, so we can exit the first
     ;time we find one already unforwarded.  If we hit the end of the
     ;list, we are done.  The first time around this loop, we write the
     ;snapped value and create an evcp to the snapped value to write on
     ;subsequent loops.

     ;Done if at the end of the copy list.
  (popj-equal m-t a-v-nil)
     ;This spreads a cons into M-A (gets car) and M-T (gets cdr)
  (call carcdr-no-sb)
     ;Read the slot in the lexical frame.
  ((vma-start-read) add m-a a-b)
  (check-page-read)
  (dispatch transport-no-evcp md)
  ((m-tem) q-typed-pointer md)
     ;If it is not the evcp, we are done, it is unshared.
  (popj-not-equal m-tem a-k)
     ;Otherwise, make it be an evcp with the right cdr codes to the copy
     ;in the first frame, or, if we are working on the first frame, the
     ;actual value that the other evcps should point to.
  ((md-start-write) selective-deposit md q-cdr-code a-c)
  (check-page-write)
  (gc-write-test)
     ;If we just wrote the value, make up an evcp to the value to use
     ;from now on.
     ;Flag in M-1 tells whether this is the first iteration.
  (jump-not-equal m-1 a-zero closure-unshare-forward-to-copy)
     ;toggle the flag.
  ((m-1) m-minus-one)
     ;Now, M-C will have an EVCP to the value, not the value itself.
  (jump-xct-next closure-unshare-forward-to-copy)
 ((m-c) dpb vma q-pointer
               (a-constant (byte-value q-data-type dtp-external-value-cell-pointer)))

CLOSURE-PREPARE-TO-POP-STACK-FRAME
     ;Move all lexical variables out of the stack and into a lexical
     ;frame.

     ;First, we snap all the evcp's in the lexical frame.
     ;Frame must exist because this is only called after a closure has
     ;been created.
  (call find-lexical-frame)
  ((m-j) q-typed-pointer c-pdl-buffer-index)
  (popj-equal m-j a-v-true)
     ;Set up for loop.
  ((vma) sub m-j (a-constant 1))

closure-prepare-to-pop-snap-first-frame
     ;Read through the evcp and write back the value, setting the cdr
     ;codes correctly.
  ((pdl-push) add vma (a-constant 1))
  ((vma-start-read) add vma (a-constant 1))
  (check-page-read)
  (dispatch transport-no-evcp md)
     ;Read through the evcp.
  ((m-1) q-cdr-code md)
  (call-xct-next pdl-fetch)
 ((vma) q-pointer md)
;  ((vma-start-read) q-pointer md)
;  (check-page-read)
   (dispatch transport md)
     ;Insert old cdr-codes into new values.
  ((m-tem) md)
  ((md) dpb m-1 q-cdr-code a-tem)
     ;Write it back.
  ((vma-start-write) pdl-pop)
  (check-page-write)
  (gc-write-test)
     ;Loop until we hit the cdr-nil.
  (jump-not-equal m-1 (a-constant (eval cdr-nil))
                  closure-prepare-to-pop-snap-first-frame)


  (call find-list-of-lexical-frame-copies)
     ;Quit if no copies, m-j gets top of original.
  (popj-equal-xct-next c-pdl-buffer-index a-v-nil)
 ((m-t) c-pdl-buffer-index)
  ((m-j) dpb m-j q-pointer (a-constant (byte-value q-data-type dtp-external-value-cell-pointer)))
     ;Setup M-K to point to beginning of args and locals of this stack
     ;frame.
  (call-xct-next convert-pdl-buffer-address)
 ((m-k) m-ap)
  ((m-k) dpb m-k q-pointer
         (a-constant (byte-value q-data-type
                                 dtp-external-value-cell-pointer)))
     ;Setup m-e to point to end of args and locals of this stack frame.
  ((pdl-index) sub pdl-index a-ap)
  ((m-e) m+a+1 pdl-index a-k)

closure-prepare-to-pop-unshare-all-frames
     ;If we are at the end, we quit.
  (popj-equal m-t a-v-nil)
     ;Spread the car and cdr.
  (call carcdr-no-sb)

     ;;We do not do this.  This is gone.
     ;Bash the evcp to the stack frame with a nil.
  ((vma m-a) sub m-a (a-constant 1))
;  ((m-tem) a-v-nil)
;  ((md-start-write) dpb m-tem q-typed-pointer (a-constant (byte-value q-cdr-code cdr-next)))
;  (check-page-write)
;  (gc-write-test)

closure-prepare-to-pop-unshare-one-frame
     ;Read the next element in the frame.
  ((vma-start-read) add vma (a-constant 1))
  (check-page-read)
  ((m-2) q-typed-pointer md)
  ((m-1) q-cdr-code md)
     ;If it doesn't point to the stack, we don't unshare it.
  (jump-less-than m-2 a-k closure-prepare-to-pop-already-unshared)
  (jump-greater-or-equal m-2 a-e closure-prepare-to-pop-already-unshared)
     ;Make up a pointer to the right location.
  ((m-2) m-a-1 vma a-a)
  ((m-2) add m-2 a-j)
     ;Write it back.
  ((md-start-write) dpb m-1 q-cdr-code a-2)
  (check-page-write)
  (gc-write-test)

closure-prepare-to-pop-already-unshared
     ;If we hit the cdr-nil, we are done.  If we don't have cdr-next,
     ;something is very wrong.
  (jump-equal m-1 (a-constant (eval cdr-nil))
                  closure-prepare-to-pop-unshare-all-frames)
  (jump-equal m-1 (a-constant (eval cdr-next))
              closure-prepare-to-pop-unshare-one-frame)
  (call illop)



;Get and set lexical variables inherited from outer contexts.

XSTORE-IN-HIGHER-CONTEXT
     ;Call load from higher context and store into the
     ;q that the vma points to.
  (misc-inst-entry %store-in-higher-context)
  (call xload-from-higher-context)
  ((m-s) dpb vma q-pointer
         (a-constant (byte-value q-data-type dtp-locative)))
  ((m-t) pdl-pop)
  (jump-xct-next xsetcar1)
 ((m-a) m-t)

XLOCATE-IN-HIGHER-CONTEXT
     ;Just call xload-from-higher-context and put the vma
     ;into M-T with dtp-locative.
  (misc-inst-entry %locate-in-higher-context)
  (call xload-from-higher-context)
  (popj-after-next no-op)
 ((m-t) dpb vma q-pointer
        (a-constant (byte-value q-data-type dtp-locative)))

XLOAD-FROM-HIGHER-CONTEXT
        (misc-inst-entry %load-from-higher-context)
     ;Returns address of slot in VMA as well as value of variable in M-T.
     ;Compute in M-T the address of a local or arg in a higher lexical context.
     ;Pops a word off the stack to specify where to find the local:
     ;  High 12. bits  Number of contexts to go up (0 => immediate higher context)
     ;  Low 12. bits      Slot number in that context.
  ((m-1) (byte-field 12. 12.) pdl-top)
     ;Quick test, if offset = 0, we start looking for the variable.
  (jump-equal-xct-next m-1 a-zero xload-from-higher-context-2)
 ((vma) dpb m-zero q-all-but-pointer a-lexical-environment)

xload-from-higher-context-1
     ;Cdr on down the lexical environment until m-1 = 0.
;  (call-xct-next pdl-fetch)
; ((vma) add vma (a-constant 1))
  ((vma-start-read) add vma (a-constant 1))
  (check-page-read)
  (dispatch transport md)
  ((vma) q-pointer md)
  (jump-greater-than-xct-next m-1 (a-constant 1) xload-from-higher-context-1)
 ((m-1) sub m-1 (a-constant 1))

xload-from-higher-context-2
     ;Take CAR of the cell we have reached, to get the lexical frame.
     ;M-C gets the index therein.
  ((vma-start-read) vma)
  (check-page-read)
; (call-xct-next pdl-fetch)
 ((m-c) (byte-field 12. 0) pdl-pop)
  (dispatch transport md)

     ;Access that word in the vector.
;  ((vma) add md a-c)
;  (call-xct-next pdl-fetch)
   ((vma-start-read) add md a-c)
   (check-page-read)  ;;; No transport, we will fake it below.

;((vma) q-pointer vma)
     ;Check explicitly for an EVCP there pointing to the pdl buffer.
     ;This is faster than transporting the usual way because we still avoid
     ;going through the page fault handler.
;#+cadr ((M-1) Q-DATA-TYPE MD)
;#+cadr (JUMP-NOT-EQUAL M-1 (A-CONSTANT (EVAL DTP-EXTERNAL-VALUE-CELL-POINTER))
;                           XLOAD-FROM-HIGHER-CONTEXT-3)
;#+lambda(jump-data-type-not-equal md
;                (a-constant (byte-value q-data-type dtp-external-value-cell-pointer))
;          xload-from-higher-context-3)
  (check-data-type-jump-not-equal md m-1 dtp-external-value-cell-pointer
                 xload-from-higher-context-3)
     ;It is an evcp, we have to indirect through it.  Also, it is likely to be in the pdl
     ;buffer, so we do this hack to avoid wasting time in the page fault routines.
  ((m-1) q-pointer md)
     ;see pdl-fetch for description of this hack
  (jump-greater-or-equal m-1 a-qlpdlh xload-from-higher-context-3)
  ((pdl-index m-2) sub m-1 a-pdl-buffer-virtual-address)
  (jump-not-equal pdl-index a-2 xload-from-higher-context-3)

     ;It is an EVCP and does point into the pdl buffer, we don't need to transport
     ;it.
  ((pdl-index) add pdl-index a-pdl-buffer-head)
  (popj-after-next (vma) q-pointer md)
 ((m-t md) q-typed-pointer pdl-index-indirect)  ;may not need to store into MD

xload-from-higher-context-3
     ;If it isn't an evcp or in the pdl buffer, just transport it.
  (dispatch transport md)
  (popj-after-next no-op)
 ((m-t) q-typed-pointer md)

PDL-FETCH
     ;MD gets contents of untyped virtual address in VMA, when likely to be in pdl buffer.
     ;Does not assume that the address is actually in the current regpdl.

     ;this is a clever hack:

     ; If the VMA is less than A-PDL-BUFFER-VIRTUAL-ADDRESS, then the subtraction
     ; will produce a negative number, which will be stored in M-2, but will be
     ; masked to 10. or 11. bits in PDL-INDEX.  Therefore, the following instruction
     ; will jump.

     ; If the VMA is bigger than A-PDL-BUFFER-VIRTUAL-ADDRESS + size-of the PDL-BUFFER
     ; then again, M-2 will contain a number bigger than will fit in PDL-INDEX, so
     ; the jump will happen.

     ; The first jump makes sure the VMA is not just past the end of the PDL buffer array.
     ; This is necessary if the hardware pdl buffer is not very full, and we are
     ; storing into the beginning of the next PDL in memory.

  (jump-greater-or-equal vma a-qlpdlh pdl-fetch-1)
  ((pdl-index m-2) sub vma a-pdl-buffer-virtual-address)
  (jump-not-equal pdl-index a-2 pdl-fetch-1)
  (popj-after-next
   (pdl-index) add pdl-index a-pdl-buffer-head)
 ((md) c-pdl-buffer-index)

pdl-fetch-1
  (popj-after-next (vma-start-read) vma)
 (check-page-read)

(end-pagable-ucode)
))
