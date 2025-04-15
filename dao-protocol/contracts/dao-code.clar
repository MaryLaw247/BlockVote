;; DAO Governance System - Stage 2
;; Enhanced implementation with improved voting and treasury management

;; Constants
(define-constant ERR-NOT-GOVERNANCE-COUNCIL (err u1))
(define-constant ERR-DAO-NOT-OPERATIONAL (err u2))
(define-constant ERR-INVALID-PROPOSAL (err u3))
(define-constant ERR-ALREADY-FINALIZED (err u4))
(define-constant ERR-INSUFFICIENT-TREASURY (err u7))
(define-constant ERR-INVALID-PARAMETER (err u8))
(define-constant ERR-PROPOSAL-EXISTS (err u9))
(define-constant MAX-PROPOSAL-ID u100) ;; Maximum allowed proposal ID

;; Data Variables
(define-data-var governance-council principal tx-sender)
(define-data-var dao-operational bool false)
(define-data-var current-voting-round uint u0)
(define-data-var governance-token-stake uint u1000000) ;; 1 STX
(define-data-var total-treasury uint u0)

;; Proposal Structure
(define-map governance-proposals
    uint
    {
        description: (string-utf8 256),
        funding-amount: uint,
        finalized: bool,
        votes: uint
    }
)

;; Member Voting Tracking
(define-map member-governance
    principal
    {
        current-proposal: uint,
        voted-proposals: (list 20 uint),
        total-votes: uint
    }
)

;; Vote History
(define-map proposal-votes
    {proposal: uint, member: principal}
    {
        vote-count: uint,
        voted-at: uint
    }
)

;; Authorization
(define-private (is-council)
    (is-eq tx-sender (var-get governance-council)))

;; DAO Management Functions
(define-public (activate-dao)
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        (var-set dao-operational true)
        (var-set current-voting-round u0)
        (var-set total-treasury u0)
        (ok true)))

(define-public (submit-proposal
    (proposal-id uint)
    (description (string-utf8 256))
    (funding-amount uint))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        
        ;; Validate proposal-id is within acceptable range
        (asserts! (<= proposal-id MAX-PROPOSAL-ID) ERR-INVALID-PARAMETER)
        
        ;; Check if proposal already exists to prevent overwriting
        (asserts! (is-none (map-get? governance-proposals proposal-id)) ERR-PROPOSAL-EXISTS)
        
        ;; Validate description is not empty
        (asserts! (> (len description) u0) ERR-INVALID-PARAMETER)
        
        ;; Validate funding amount is a positive amount
        (asserts! (> funding-amount u0) ERR-INVALID-PARAMETER)
        
        ;; Set the proposal data
        (map-set governance-proposals proposal-id
            {
                description: description,
                funding-amount: funding-amount,
                finalized: false,
                votes: u0
            })
            
        ;; Calculate new treasury safely
        (let ((new-treasury (+ (var-get total-treasury) funding-amount)))
            ;; Make sure the addition doesn't overflow
            (asserts! (>= new-treasury (var-get total-treasury)) ERR-INVALID-PARAMETER)
            ;; Update the total treasury
            (var-set total-treasury new-treasury))
        (ok true)))

;; Member Registration
(define-public (stake-governance-tokens)
    (begin
        (asserts! (var-get dao-operational) ERR-DAO-NOT-OPERATIONAL)
        ;; Require governance token stake
        (try! (stx-transfer? (var-get governance-token-stake) tx-sender (var-get governance-council)))
        
        (map-set member-governance tx-sender
            {
                current-proposal: u0,
                voted-proposals: (list),
                total-votes: u0
            })
        (ok true)))

;; Update governance token stake
(define-public (update-token-stake (new-stake uint))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        (asserts! (> new-stake u0) ERR-INVALID-PARAMETER)
        (var-set governance-token-stake new-stake)
        (ok true)))

;; Voting Functions
(define-public (vote-on-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-INVALID-PROPOSAL))
        (member (unwrap! (map-get? member-governance tx-sender) ERR-INVALID-PROPOSAL))
        (block-height block-height)
        )
        ;; Check proposal availability
        (asserts! (var-get dao-operational) ERR-DAO-NOT-OPERATIONAL)
        (asserts! (not (get finalized proposal)) ERR-ALREADY-FINALIZED)
        
        ;; Update proposal with vote count
        (map-set governance-proposals proposal-id
            (merge proposal {
                votes: (+ (get votes proposal) u1)
            }))
        
        ;; Update member governance record
        (map-set member-governance tx-sender
            (merge member {
                current-proposal: (+ proposal-id u1),
                voted-proposals: (unwrap! (as-max-len? 
                    (append (get voted-proposals member) proposal-id) u20)
                    ERR-INVALID-PARAMETER),
                total-votes: (+ (get total-votes member) u1)
            }))
        
        ;; Record vote
        (map-set proposal-votes
            {proposal: proposal-id, member: tx-sender}
            {
                vote-count: u1,
                voted-at: block-height
            })
        
        (ok true)))

;; Finalize proposal after voting
(define-public (finalize-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-INVALID-PROPOSAL))
        )
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        (asserts! (not (get finalized proposal)) ERR-ALREADY-FINALIZED)
        
        ;; Check if proposal has votes
        (asserts! (> (get votes proposal) u0) ERR-INVALID-PARAMETER)
        
        ;; Check treasury has enough funds
        (asserts! (>= (var-get total-treasury) (get funding-amount proposal)) ERR-INSUFFICIENT-TREASURY)
        
        ;; Update proposal status
        (map-set governance-proposals proposal-id
            (merge proposal {finalized: true}))
        
        ;; Update treasury
        (var-set total-treasury (- (var-get total-treasury) (get funding-amount proposal)))
        
        ;; Transfer funding to governance council for distribution
        (var-set current-voting-round (+ (var-get current-voting-round) u1))
        
        (ok true)))

;; Treasury management
(define-public (deposit-to-treasury (amount uint))
    (begin
        (asserts! (var-get dao-operational) ERR-DAO-NOT-OPERATIONAL)
        (try! (stx-transfer? amount tx-sender (var-get governance-council)))
        (var-set total-treasury (+ (var-get total-treasury) amount))
        (ok true)))

;; Read-only functions
(define-read-only (get-proposal (proposal-id uint))
    (map-get? governance-proposals proposal-id))

(define-read-only (get-member-status (member principal))
    (map-get? member-governance member))

(define-read-only (get-proposal-votes (proposal-id uint) (voter principal))
    (map-get? proposal-votes {proposal: proposal-id, member: voter}))

(define-read-only (get-dao-stats)
    {
        operational: (var-get dao-operational),
        current-voting-round: (var-get current-voting-round),
        total-treasury: (var-get total-treasury),
        governance-token-stake: (var-get governance-token-stake)
    })