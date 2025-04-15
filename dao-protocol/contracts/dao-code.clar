;; DAO Governance System 
;; Implementation with minimal governance functionality

;; Constants
(define-constant ERR-NOT-GOVERNANCE-COUNCIL (err u1))
(define-constant ERR-DAO-NOT-OPERATIONAL (err u2))
(define-constant ERR-INVALID-PROPOSAL (err u3))
(define-constant ERR-ALREADY-FINALIZED (err u4))

;; Data Variables
(define-data-var governance-council principal tx-sender)
(define-data-var dao-operational bool false)
(define-data-var total-treasury uint u0)

;; Proposal Structure
(define-map governance-proposals
    uint
    {
        description: (string-utf8 256),
        funding-amount: uint,
        finalized: bool
    }
)

;; Member Registration
(define-map member-governance
    principal
    {
        current-proposal: uint,
        total-votes: uint
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
        (ok true)))

(define-public (submit-proposal
    (proposal-id uint)
    (description (string-utf8 256))
    (funding-amount uint))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        
        ;; Validate description is not empty
        (asserts! (> (len description) u0) ERR-INVALID-PROPOSAL)
        
        ;; Validate funding amount is a positive amount
        (asserts! (> funding-amount u0) ERR-INVALID-PROPOSAL)
        
        ;; Set the proposal data
        (map-set governance-proposals proposal-id
            {
                description: description,
                funding-amount: funding-amount,
                finalized: false
            })
            
        ;; Update the total treasury
        (var-set total-treasury (+ (var-get total-treasury) funding-amount))
        (ok true)))

;; Member Registration
(define-public (register-member)
    (begin
        (asserts! (var-get dao-operational) ERR-DAO-NOT-OPERATIONAL)
        
        (map-set member-governance tx-sender
            {
                current-proposal: u0,
                total-votes: u0
            })
        (ok true)))

;; Voting Functions
(define-public (vote-on-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-INVALID-PROPOSAL))
        (member (unwrap! (map-get? member-governance tx-sender) ERR-INVALID-PROPOSAL))
        )
        ;; Check proposal availability
        (asserts! (var-get dao-operational) ERR-DAO-NOT-OPERATIONAL)
        (asserts! (not (get finalized proposal)) ERR-ALREADY-FINALIZED)
        
        ;; Update proposal status
        (map-set governance-proposals proposal-id
            (merge proposal {finalized: true}))
        
        ;; Update member governance record
        (map-set member-governance tx-sender
            (merge member {
                current-proposal: (+ proposal-id u1),
                total-votes: (+ (get total-votes member) u1)
            }))
        
        ;; Transfer funding allocation
        (try! (stx-transfer? (get funding-amount proposal) (var-get governance-council) tx-sender))
        
        (ok true)))

;; Read-only functions
(define-read-only (get-proposal-description (proposal-id uint))
    (match (map-get? governance-proposals proposal-id)
        proposal (ok (get description proposal))
        ERR-INVALID-PROPOSAL))

(define-read-only (get-member-status (member principal))
    (map-get? member-governance member))

(define-read-only (get-dao-stats)
    {
        operational: (var-get dao-operational),
        total-treasury: (var-get total-treasury)
    })