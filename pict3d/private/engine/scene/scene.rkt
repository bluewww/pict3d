#lang typed/racket/base

#|
Scenes: tree-structured databases that
 * Approximately self-balance
 * Store shapes in the leaves
 * Store bounding information in the nodes and leaves

Scenes should allow O(log(n))
 * Approximate plane culling (i.e. for view and shadow frustum culling)
 * Collision queries (i.e. point, sphere, or box tracing)
 * Touching queries and other spatial searches

This module also contains code for `frozen-scene-shape` that would normally go in its own module. But
moving this code to another module would cause a cycle, and the only way to break it is to
parameterize scenes on shapes and shape operations instead of having them baked in. That used to be
how the code was organized, but it made the predicate for the scene type O(n). As it is now, with no
parametric polymorphism and no higher-order types, Typed Racket should generate an O(1) flat contract
for `Scene`.
|#

(require racket/unsafe/ops
         racket/match
         racket/flonum
         racket/vector
         racket/list
         racket/fixnum
         (except-in typed/opengl/ffi -> cast)
         "../../math/flv3.rkt"
         "../../math/flt3.rkt"
         "../../math/flrect3.rkt"
         "../../gl.rkt"
         "../../utils.rkt"
         "../draw-pass.rkt"
         "../draw-passes.rkt"
         "../affine.rkt"
         "../types.rkt"
         "../utils.rkt"
         "types.rkt"
         "shape.rkt")

(provide (all-defined-out))

;; ===================================================================================================
;; Scene constructors

(: shape->scene (-> Shape Nonempty-Scene))
(define (shape->scene a)
  (scene-leaf (shape-rect a) 1 a))

(: make-nonempty-scene-node (-> Nonempty-Scene Nonempty-Scene Nonempty-Scene))
(define (make-nonempty-scene-node s1 s2)
  (define c (fx+ (nonempty-scene-count s1) (nonempty-scene-count s2)))
  (define b (flrect3-join (scene-rect s1) (scene-rect s2)))
  (scene-node b c s1 s2))

(: make-scene-node (-> Scene Scene Scene))
(define (make-scene-node s1 s2)
  (cond [(empty-scene? s1)  s2]
        [(empty-scene? s2)  s1]
        [else  (make-nonempty-scene-node s1 s2)]))

(: make-nonempty-scene-tran (-> FlAffine3- Nonempty-Scene Nonempty-Scene))
(define (make-nonempty-scene-tran t s)
  (if (scene-tran? s)
      (make-nonempty-scene-tran (flt3compose t (scene-tran-transform s))
                                (scene-tran-scene s))
      (scene-tran (flrect3-transform (scene-rect s) t) (nonempty-scene-count s) t s)))

(: scene-transform (-> Scene FlAffine3- Scene))
(define (scene-transform s t)
  (if (empty-scene? s) s (make-nonempty-scene-tran t s)))

;; ===================================================================================================
;; Scene union with rebalancing

(: nonempty-scene-union (-> Nonempty-Scene Nonempty-Scene Nonempty-Scene))
(define (nonempty-scene-union s1 s2)
  (define s (make-nonempty-scene-node s1 s2))
  (define c (nonempty-scene-count s))
  (cond [(<= c 4)  s]
        [(> (integer-length c)
            (integer-length (max (nonempty-scene-count s1)
                                 (nonempty-scene-count s2))))
         (scene-rebalance s)]
        [else
         (scene-rebalance s 2)]))

(: scene-union (-> Scene Scene Scene))
(define (scene-union s1 s2)
  (cond [(empty-scene? s1)  s2]
        [(empty-scene? s2)  s1]
        [else  (nonempty-scene-union s1 s2)]))

(: scene-union* (-> (Listof Scene) Scene))
(define (scene-union* ss)
  (cond
    [(empty? ss)  empty-scene]
    [else
     (: s Scene)
     (define s
       (let loop ([ss : (Pair Scene (Listof Scene))  ss])
         (define n/2 (fxquotient (length ss) 2))
         (define ss1 (take ss n/2))
         (define ss2 (drop ss n/2))
         (cond [(empty? ss1)  (first ss2)]
               [(empty? ss2)  (first ss1)]  ; can't happen
               [else
                (define s (make-scene-node (loop ss1) (loop ss2)))
                (if (or (empty-scene? s)
                        (<= (nonempty-scene-count s) 4))
                    s
                    (scene-rebalance s 2))])))
     
     (define c (scene-count s))
     (cond [(or (empty-scene? s) (<= c 4))  s]
           [(> (integer-length c)
               (integer-length (for/fold ([mx : Nonnegative-Fixnum  0]) ([s  (in-list ss)])
                                 (max mx (scene-count s)))))
            (scene-rebalance s)]
           [else  s])]))

;; ===================================================================================================
;; Rebalance

(define max-index 268435455)

(: scene-rebalance-split (-> Nonempty-Scene Index Flonum Index (Values Scene Scene)))
(define (scene-rebalance-split s i x d)
  (let loop ([s s] [d d])
    (cond
      [(or (= d 0) (scene-leaf? s) (scene-tran? s))
       (define b (scene-rect s))
       (define xmin (flvector-ref (flrect3-min b) i))
       (define xmax (flvector-ref (flrect3-max b) i))
       (if (< (- x xmin) (- xmax x))
           (values s empty-scene)
           (values empty-scene s))]
      [(scene-node? s)
       (define-values (s11 s12) (loop (scene-node-neg s) (- d 1)))
       (define-values (s21 s22) (loop (scene-node-pos s) (- d 1)))
       (values (make-scene-node s11 s21)
               (make-scene-node s12 s22))])))

(: scene-rebalance-children (-> Nonempty-Scene Index Nonempty-Scene))
(define (scene-rebalance-children s d)
  (match s
    [(? scene-leaf? s)  s]
    [(? scene-tran? s)  s]
    [(scene-node b c s1 s2)
     (scene-node b c
                 (scene-rebalance s1 d)
                 (scene-rebalance s2 d))]))

(: scene-rebalance (->* [Nonempty-Scene] [Index] Nonempty-Scene))
(define (scene-rebalance s [d max-index])
  (cond
    [(or (= d 0) (scene-leaf? s) (scene-tran? s))  s]
    [(scene-node? s)
     (match-define (scene-node b c s1 s2) s)
     (define-values (i x) (flrect3-longest-axis/center b))
     (define-values (s11 s12) (scene-rebalance-split s1 i x d))
     (define-values (s21 s22) (scene-rebalance-split s2 i x d))
     (cond
       [(and s11 (not s12) (not s21) s22)  s]
       [(and (not s11) s12 s21 (not s22))  s]
       [else
        (let ([s1  (make-scene-node s11 s21)]
              [s2  (make-scene-node s12 s22)])
          (cond [(empty-scene? s1)  (scene-rebalance-children (assert s2 nonempty-scene?)
                                                              (- d 1))]
                [(empty-scene? s2)  (scene-rebalance-children s1 (- d 1))]
                [else  (scene-node b c
                                   (scene-rebalance s1 (- d 1))
                                   (scene-rebalance s2 (- d 1)))]))])]))

;; ===================================================================================================
;; Filter, and tastes-almost-but-not-quite-entirely-unlike-map

(: scene-filter (-> Scene (-> Shape Boolean) Scene))
(define (scene-filter s p?)
  (let loop ([s s])
    (match s
      [(? empty-scene? s)  s]
      [(scene-leaf b c a)
       (if (p? a) s empty-scene)]
      [(scene-node b c s1 s2)
       (define new-s1 (loop s1))
       (define new-s2 (loop s2))
       (cond [(and (eq? new-s1 s1) (eq? new-s2 s2))  s]
             [(empty-scene? new-s1)  new-s2]
             [(empty-scene? new-s2)  new-s1]
             [else  (make-nonempty-scene-node new-s1 new-s2)])]
      [(scene-tran b c t0 s0)
       (define new-s0 (loop s0))
       (cond [(eq? new-s0 s0)  s]
             [(empty-scene? new-s0)  new-s0]
             [else  (make-nonempty-scene-tran t0 new-s0)])])))

(: nonempty-scene-extract (All (B C) (-> Nonempty-Scene
                                         C (-> C FlAffine3- C)
                                         (Listof FlPlane3)
                                         (-> Shape C B)
                                         (Listof B))))
(define (nonempty-scene-extract s c-id c-compose planes f)
  (let loop ([s s] [c : C  c-id] [planes : (Listof FlPlane3)  planes] [parent-inside? : Boolean  #f])
    (: side (U 'inside 'outside 'both))
    (define side
      (cond [parent-inside?  'inside]
            [(< (scene-count s) 4)  'inside]
            [else  (flrect3-classify/planes (scene-rect s) planes)]))
    (define inside? (eq? side 'inside))
    (cond
      [(eq? side 'outside)   empty]
      [(scene-leaf? s)
       (list (f (scene-leaf-shape s) c))]
      [(scene-node? s)
       (append (loop (scene-node-neg s) c planes inside?)
               (loop (scene-node-pos s) c planes inside?))]
      [(scene-tran? s)
       (match-define (scene-tran _ _ t0 s0) s)
       (define new-c (c-compose c t0))
       (define tinv0 (flt3inverse t0))
       (define new-planes
         (for/fold ([planes : (Listof FlPlane3)  empty]) ([p  (in-list planes)])
           (define new-p (flt3apply/pln tinv0 p))
           (if new-p (cons new-p planes) planes)))
       (loop s0 new-c new-planes inside?)])))

(: scene-extract (All (B C) (-> Scene C (-> C FlAffine3- C) (Listof FlPlane3) (-> Shape C B)
                                (Listof B))))
(define (scene-extract s c-id c-compose planes f)
  (if (empty-scene? s)
      empty
      (nonempty-scene-extract s c-id c-compose planes f)))

;; ===================================================================================================
;; Shape bounding box

(: shape-rect (-> Shape Nonempty-FlRect3))
(define (shape-rect a)
  (cond
    [(solid-shape? a)
     (cond
       [(triangle-shape? a)   (triangle-shape-rect a)]
       [(rectangle-shape? a)  (rectangle-shape-rect a)]
       [(sphere-shape? a)     (sphere-shape-rect a)])]
    [(light-shape? a)
     (cond
       [(directional-light-shape? a)  directional-light-shape-rect]
       [(point-light-shape? a)        (point-light-shape-rect a)])]
    [(frozen-scene-shape? a)
     (frozen-scene-shape-rect a)]))

;; ===================================================================================================
;; Scene plane culling

(: nonempty-scene-plane-cull (-> Nonempty-Scene FlPlane3 Scene))
(define (nonempty-scene-plane-cull s p)
  (let loop ([s s] [p p])
    (define side (flrect3-plane-side (scene-rect s) p))
    (cond
      [(or (eq? side 'pos) (eq? side 'poszero) (eq? side 'zero))  s]
      [(eq? side 'neg)  empty-scene]
      ;; side is either 'negzero or 'both
      [(scene-leaf? s)  s]
      [(scene-node? s)
       (match-define (scene-node b c s1 s2) s)
       (define new-s1 (loop s1 p))
       (define new-s2 (loop s2 p))
       (cond [(and (eq? new-s1 s1) (eq? new-s2 s2))  s]
             [(empty-scene? new-s1)  new-s2]
             [(empty-scene? new-s2)  new-s1]
             [else  (make-nonempty-scene-node new-s1 new-s2)])]
      [(scene-tran? s)
       (match-define (scene-tran b c t s0) s)
       (define new-p (flt3apply/pln (flt3inverse t) p))
       (cond [new-p
              (define new-s0 (loop s0 new-p))
              (cond [(eq? new-s0 s0)  s]
                    [(empty-scene? new-s0)  new-s0]
                    [else  (make-nonempty-scene-tran t new-s0)])]
             [else
              empty-scene])])))

(: scene-plane-cull (-> Scene FlPlane3 Scene))
(define (scene-plane-cull s p)
  (if (empty-scene? s)
      s
      (nonempty-scene-plane-cull s p)))

;; ===================================================================================================
;; Scene rect culling

(: nonempty-scene-rect-cull (-> Nonempty-Scene FlRect3 Scene))
(define (nonempty-scene-rect-cull s orig-b)
  (let loop ([s s] [t : FlAffine3-  identity-flt3] [b orig-b])
    (cond
      [(flrect3-contains-rect? b (scene-rect s))  s]
      [(flrect3-disjoint? b (scene-rect s))  empty-scene]
      ;; The shape's bounding box is partly inside and partly outside
      [(scene-leaf? s)  s]
      [(scene-node? s)
       (match-define (scene-node b0 c0 s1 s2) s)
       (define new-s1 (loop s1 t b))
       (define new-s2 (loop s2 t b))
       (cond [(and (eq? new-s1 s1) (eq? new-s2 s2))  s]
             [(empty-scene? new-s1)  new-s2]
             [(empty-scene? new-s2)  new-s1]
             [else  (make-nonempty-scene-node new-s1 new-s2)])]
      [(scene-tran? s)
       (match-define (scene-tran b0 c0 t0 s0) s)
       (define new-t (flt3compose (flt3inverse t0) t))
       (define new-b (flrect3-transform orig-b new-t))
       (define new-s0 (loop s0 new-t new-b))
       (cond [(eq? new-s0 s0)  s]
             [(empty-scene? new-s0)  new-s0]
             [else  (make-nonempty-scene-tran t0 new-s0)])])))

(: scene-rect-cull (-> Scene FlRect3 Scene))
(define (scene-rect-cull s b)
  (if (empty-scene? s)
      empty-scene
      (for/fold ([s : Scene  (nonempty-scene-rect-cull s b)]
                 ) ([p  (in-list (flrect3-inside-planes b))])
        (scene-plane-cull s p))))

;; ===================================================================================================
;; Scene frustum culling

(: scene-frustum-cull (-> Scene FlTransform3 Scene))
(define (scene-frustum-cull s t)
  (define planes (flprojective3-frustum-planes (->flprojective3 t)))
  (for/fold ([s : Scene  s]) ([p  (in-list planes)])
    (scene-plane-cull s p)))

;; ===================================================================================================
;; Shape and scene transformation (forced, not lazy)

(: shape-transform (-> Shape FlAffine3- (Listof Shape)))
(define (shape-transform a t)
  (cond
    [(flidentity3? t)  (list a)]
    [(solid-shape? a)
     (cond
       [(triangle-shape? a)   (triangle-shape-transform a t)]
       [(rectangle-shape? a)  (rectangle-shape-transform a t)]
       [(sphere-shape? a)     (sphere-shape-transform a t)])]
    [(light-shape? a)
     (cond
       [(directional-light-shape? a)  (directional-light-shape-transform a t)]
       [(point-light-shape? a)        (point-light-shape-transform a t)])]
    ;; Frozen scene
    [(frozen-scene-shape? a)
     (frozen-scene-shape-transform a t)]))

(: nonempty-transform-shapes (-> Nonempty-Scene FlAffine3- Scene))
(define (nonempty-transform-shapes s t)
  (match s
    [(scene-leaf b c a)
     (scene-union* (map shape->scene (shape-transform a t)))]
    [(scene-node b c s1 s2)
     (make-scene-node (nonempty-transform-shapes s1 t)
                      (nonempty-transform-shapes s2 t))]
    [(scene-tran b c t0 s0)
     (nonempty-transform-shapes s0 (flt3compose t t0))]))

(: scene-transform-shapes (-> Scene FlAffine3- Scene))
(define (scene-transform-shapes s t)
  (if (empty-scene? s) s (nonempty-transform-shapes s t)))

;; ===================================================================================================
;; Scene drawing

(: shape-passes (-> Shape Passes))
(define (shape-passes a)
  (lazy-box-ref!
   (shape-lazy-passes a)
   (λ ()
     (cond
       [(solid-shape? a)
        (cond
          [(triangle-shape? a)   (make-triangle-shape-passes a)]
          [(rectangle-shape? a)  (make-rectangle-shape-passes a)]
          [(sphere-shape? a)     (make-sphere-shape-passes a)])]
       [(light-shape? a)
        (cond
          [(directional-light-shape? a)  (make-directional-light-shape-passes a)]
          [(point-light-shape? a)        (make-point-light-shape-passes a)])]
       [(frozen-scene-shape? a)
        (make-frozen-scene-shape-passes a)]))))

(: scene-draw-passes (-> Scene (Listof FlPlane3) (Listof draw-passes)))
(define (scene-draw-passes s planes)
  ((inst scene-extract draw-passes affine)
   s
   identity-affine
   affine-compose
   planes
   (λ ([a : Shape] [m : affine])
     (draw-passes (shape-passes a) m))))

(: draw-scene (-> Scene Natural Natural FlAffine3- FlTransform3 FlVector FlVector Flonum Void))
(define (draw-scene s width height view proj background ambient-color ambient-intensity)
  (define t (flt3compose proj view))
  (define planes (flprojective3-frustum-planes (->flprojective3 t)))
  (draw-draw-passes (list->vector (scene-draw-passes s planes)) width height
                    view proj
                    background ambient-color ambient-intensity))

;; ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
;; Frozen scene shape

;; ===================================================================================================
;; Constructors

(: make-frozen-scene-shape (-> Nonempty-Scene Shape))
(define (make-frozen-scene-shape s)
  (frozen-scene-shape (box 'lazy) s))

;; ===================================================================================================
;; Passes

(: get-vertex-count (-> Boolean
                        (Vectorof shape-params)
                        Nonnegative-Fixnum
                        Nonnegative-Fixnum
                        Nonnegative-Fixnum))
(define (get-vertex-count indexed? ps start end)
  (for/fold ([vertex-count : Nonnegative-Fixnum  0]) ([i  (in-range start end)])
    (define v (shape-params-vertices (unsafe-vector-ref ps i)))
    (if (eq? indexed? (and (vertices-indexes v) #t))
        (unsafe-fx+ vertex-count (vertices-vertex-count v))
        vertex-count)))

(: get-index-count (-> (Vectorof shape-params)
                       Nonnegative-Fixnum
                       Nonnegative-Fixnum
                       Nonnegative-Fixnum))
(define (get-index-count ps start end)
  (for/fold ([index-count : Nonnegative-Fixnum  0]) ([i  (in-range start end)])
    (define v (shape-params-vertices (unsafe-vector-ref ps i)))
    (define indexes (vertices-indexes v))
    (if indexes
        (unsafe-fx+ index-count (vector-length indexes))
        index-count)))

(: merge-vertex-data (-> program-spec
                         Boolean
                         (Vectorof shape-params)
                         Nonnegative-Fixnum
                         Nonnegative-Fixnum
                         Nonnegative-Fixnum
                         Bytes))
(define (merge-vertex-data pd indexed? ps start end vertex-count)
  (define struct-size (vao-struct-size (gl-program-struct (program-spec-program pd))))
  (define buffer-size (unsafe-fx* vertex-count struct-size))
  (define all-vertex-data (make-bytes buffer-size))
  (define all-vertex-data-ptr (u8vector->cpointer all-vertex-data))
  ;; Copy the vertex data into the buffer
  (for/fold ([vertex-num : Nonnegative-Fixnum  0]) ([i  (in-range start end)])
    (define v (shape-params-vertices (unsafe-vector-ref ps i)))
    (cond
      [(eq? indexed? (and (vertices-indexes v) #t))
       (define vertex-count (vertices-vertex-count v))
       (define vertex-data (vertices-vertex-data v))
       (memcpy all-vertex-data-ptr
               (unsafe-fx* vertex-num struct-size)
               (u8vector->cpointer vertex-data)
               (unsafe-fx* vertex-count struct-size)
               _byte)
       (unsafe-fx+ vertex-num vertex-count)]
      [else
       vertex-num]))
  all-vertex-data)

(: merge-indexes (-> (Vectorof shape-params)
                     Nonnegative-Fixnum
                     Nonnegative-Fixnum
                     (Vectorof Index)))
(define (merge-indexes ps start end)
  (define index-count (get-index-count ps start end))
  (define all-indexes ((inst make-vector Index) index-count))
  
  ;; Copy the index data into the buffer, shifted
  (for/fold ([vertex-num : Nonnegative-Fixnum  0]
             [index-num : Nonnegative-Fixnum 0]
             ) ([i  (in-range start end)])
    (define v (shape-params-vertices (unsafe-vector-ref ps i)))
    (define indexes (vertices-indexes v))
    (cond
      [indexes
       (define vertex-count (vertices-vertex-count v))
       (define index-count (vector-length indexes))
       (for ([j  (in-range index-count)])
         (define idx (unsafe-vector-ref indexes j))
         (vector-set! all-indexes
                      (unsafe-fx+ index-num j)
                      (assert (unsafe-fx+ vertex-num idx) index?)))
       (values (unsafe-fx+ vertex-num vertex-count)
               (unsafe-fx+ index-num index-count))]
      [else
       (values vertex-num
               index-num)]))
  all-indexes)

(: merge-vertices (-> program-spec
                      Boolean
                      (List-Hash String (U Symbol Uniform))
                      Boolean
                      Integer
                      (Vectorof shape-params)
                      Nonnegative-Fixnum
                      Nonnegative-Fixnum
                      (Listof shape-params)))
(define (merge-vertices pd indexed? uniforms two-sided? mode ps start end)
  (define vertex-count (get-vertex-count indexed? ps start end))
  (cond
    [(> vertex-count max-shape-vertex-count)
     (define mid (unsafe-fxquotient (unsafe-fx+ start end) 2))
     (when (or (= start mid) (= end mid))
       (error 'merge-vertices
              "cannot merge a single shape with more than ~a vertices; given ~a vertices"
              max-shape-vertex-count
              vertex-count))
     (append
      (merge-vertices pd indexed? uniforms two-sided? mode ps start mid)
      (merge-vertices pd indexed? uniforms two-sided? mode ps mid end))]
    [(> vertex-count 0)
     ;; Allocate enough space for all the vertex data
     (define all-vertex-data (merge-vertex-data pd indexed? ps start end vertex-count))
     (define all-indexes (if indexed? (merge-indexes ps start end) #f))
     
     (define verts (vertices (assert vertex-count index?) all-vertex-data all-indexes))
     (list (shape-params (λ () pd) uniforms two-sided? mode verts))]
    [else
     empty]))

(: make-frozen-scene-shape-passes (-> frozen-scene-shape Passes))
(define (make-frozen-scene-shape-passes a)
  (define s (frozen-scene-shape-scene a))
  
  (: transformed-passes (-> Shape FlAffine3- (Listof Passes)))
  (define (transformed-passes s t)
    (map shape-passes (shape-transform s t)))
  
  (define ps (append* (scene-extract (scene-transform-shapes s identity-flt3)
                                     identity-flt3
                                     flt3compose
                                     empty
                                     transformed-passes)))
  (define num-passes (apply max (map vector-length ps)))
  
  (: get-swap-params (-> Integer (Vectorof shape-params)))
  (define (get-swap-params n)
    (make-vector n empty-shape-params))
  
  (list->vector
   (for/list : (Listof (Vectorof shape-params)) ([pass  (in-range num-passes)])
     (let* ([ps  (map (λ ([p : Passes])
                        (if (< pass (vector-length p)) (vector-ref p pass) #()))
                      ps)]
            [ps  (apply vector-append ps)])
       (list->vector
        (append*
         (for*/list : (Listof (Listof shape-params))
           ([s  (in-list (group-by-key! ps get-swap-params 0 (vector-length ps)
                                        shape-params-program-spec))]
            [pd  (in-value ((span-key s)))]
            [s  (in-list (group-by-key! ps get-swap-params (span-start s) (span-end s)
                                        shape-params-uniforms))]
            [uniforms  (in-value (span-key s))]
            [s  (in-list (group-by-key! ps get-swap-params (span-start s) (span-end s)
                                        shape-params-two-sided?))]
            [face  (in-value (span-key s))]
            [s  (in-list (group-by-key! ps get-swap-params (span-start s) (span-end s)
                                        shape-params-mode))]
            [mode  (in-value (span-key s))])
           (append
            (merge-vertices pd #f uniforms face mode ps (span-start s) (span-end s))
            (merge-vertices pd #t uniforms face mode ps (span-start s) (span-end s))))))))))

;; ===================================================================================================
;; Bounding box

(: frozen-scene-shape-rect (-> frozen-scene-shape Nonempty-FlRect3))
(define (frozen-scene-shape-rect a)
  (scene-rect (frozen-scene-shape-scene a)))

;; ===================================================================================================
;; Transform

(: frozen-scene-shape-transform (-> frozen-scene-shape FlAffine3- (Listof Shape)))
(define (frozen-scene-shape-transform a t)
  (append*
   (scene-extract (scene-transform-shapes (frozen-scene-shape-scene a) t)
                  identity-flt3
                  flt3compose
                  empty
                  shape-transform)))