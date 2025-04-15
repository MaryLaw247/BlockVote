;; DAO Governance System - Stage 3
;; A blockchain-based governance platform with sequential proposals, token-based voting,
;; timelock functionality, and vote signature verification

;; Constants
(define-constant ERR-NOT-GOVERNANCE-COUNCIL (err u1))
(define-constant ERR-DAO-NOT-OPERATIONAL (err u2))
(define-constant ERR-INVALID-PROPOSAL (err u3))
(define-constant ERR-ALREADY-FINALIZED (err u4))
(define-constant ERR-WRONG-VOTE-SIGNATURE (err u5))
(define-constant ERR-VOTING-PERIOD-ACTIVE (err u6))
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
(define-data-var current-timelock uint u0) ;; Timelock tracking for voting periods

;; Proposal Structure
(define-map governance-proposals
    uint
    {
        description: (string-utf8 256),
        vote-signature: (buff 32), ;; SHA256 hash of the expected vote confirmation
        timelock-end: uint,        ;; Timelock end for the voting period
        funding-amount: uint,
        finalized: bool
    }
)

;; Member Voting Tracking
(define-map member-governance
    principal
    {
        current-proposal: uint,
        voted-proposals: (list 20 uint),
        last-vote: uint,
        total-votes: uint
    }
)

;; Vote History
(define-map proposal-votes
    {proposal: uint, member: principal}
    {
        vote-count: uint,
        voted-at: (optional uint)
    }
)

;; Events
(define-map voting-results
    uint
    (list 10 {member: principal, voted-at: uint})
)

;; Authorization
(define-private (is-council)
    (is-eq tx-sender (var-get governance-council)))

;; Timelock Management
(define-public (update-timelock (new-timelock uint))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        ;; Validate timelock is not in the past
        (asserts! (>= new-timelock (var-get current-timelock)) ERR-INVALID-PARAMETER)
        (var-set current-timelock new-timelock)
        (ok true)))

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
    (vote-signature (buff 32))
    (timelock-end uint)
    (funding-amount uint))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        
        ;; Validate proposal-id is within acceptable range
        (asserts! (<= proposal-id MAX-PROPOSAL-ID) ERR-INVALID-PARAMETER)
        
        ;; Check if proposal already exists to prevent overwriting
        (asserts! (is-none (map-get? governance-proposals proposal-id)) ERR-PROPOSAL-EXISTS)
        
        ;; Validate timelock end is in the future
        (asserts! (>= timelock-end (var-get current-timelock)) ERR-INVALID-PARAMETER)
        
        ;; Validate vote signature is not empty
        (asserts! (> (len vote-signature) u0) ERR-INVALID-PARAMETER)
        
        ;; Validate description is not empty
        (asserts! (> (len description) u0) ERR-INVALID-PARAMETER)
        
        ;; Validate funding amount is a positive amount
        (asserts! (> funding-amount u0) ERR-INVALID-PARAMETER)
        
        ;; Set the proposal data
        (map-set governance-proposals proposal-id
            {
                description: description,
                vote-signature: vote-signature,
                timelock-end: timelock-end,
                funding-amount: funding-amount,
                finalized: false
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
                last-vote: u0,
                total-votes: u0
            })
        (ok true)))

;; Voting Functions
(define-public (cast-vote
    (proposal-id uint)
    (vote-confirmation (buff 32)))
    (let (
        (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-INVALID-PROPOSAL))
        (member (unwrap! (map-get? member-governance tx-sender) ERR-INVALID-PROPOSAL))
        (current-time (var-get current-timelock))
        )
        ;; Check proposal availability
        (asserts! (var-get dao-operational) ERR-DAO-NOT-OPERATIONAL)
        (asserts! (>= current-time (get timelock-end proposal)) ERR-VOTING-PERIOD-ACTIVE)
        (asserts! (not (get finalized proposal)) ERR-ALREADY-FINALIZED)
        
        ;; Verify vote confirmation - directly compare the signatures
        (if (is-eq vote-confirmation (get vote-signature proposal))
            (begin
                ;; Update proposal status
                (map-set governance-proposals proposal-id
                    (merge proposal {finalized: true}))
                
                ;; Update member governance record
                (map-set member-governance tx-sender
                    (merge member {
                        current-proposal: (+ proposal-id u1),
                        voted-proposals: (unwrap! (as-max-len? 
                            (append (get voted-proposals member) proposal-id) u20)
                            ERR-INVALID-PROPOSAL),
                        last-vote: current-time,
                        total-votes: (+ (get total-votes member) u1)
                    }))
                
                ;; Record vote
                (map-set proposal-votes
                    {proposal: proposal-id, member: tx-sender}
                    {
                        vote-count: u1,
                        voted-at: (some current-time)
                    })
                
                ;; Transfer funding allocation
                (try! (stx-transfer? (get funding-amount proposal) (var-get governance-council) tx-sender))
                
                ;; Record voting result
                (match (map-get? voting-results proposal-id)
                    results (map-set voting-results proposal-id
                        (unwrap! (as-max-len?
                            (append results {member: tx-sender, voted-at: current-time})
                            u10)
                            ERR-INVALID-PROPOSAL))
                    (map-set voting-results proposal-id
                        (list {member: tx-sender, voted-at: current-time})))
                
                (ok true))
            ERR-WRONG-VOTE-SIGNATURE)))

;; Read-only functions
(define-read-only (get-proposal-description (proposal-id uint))
    (match (map-get? governance-proposals proposal-id)
        proposal (if (>= (var-get current-timelock) (get timelock-end proposal))
            (ok (get description proposal))
            ERR-VOTING-PERIOD-ACTIVE)
        ERR-INVALID-PROPOSAL))

(define-read-only (get-member-status (member principal))
    (map-get? member-governance member))

(define-read-only (get-voting-results (proposal-id uint))
    (map-get? voting-results proposal-id))

(define-read-only (get-current-timelock)
    (var-get current-timelock))

(define-read-only (get-dao-stats)
    {
        operational: (var-get dao-operational),
        current-voting-round: (var-get current-voting-round),
        total-treasury: (var-get total-treasury),
        governance-token-stake: (var-get governance-token-stake),
        current-timelock: (var-get current-timelock)
    })

;; Transfer governance council
(define-public (transfer-governance (new-council principal))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        (asserts! (not (is-eq new-council (var-get governance-council))) ERR-INVALID-PARAMETER)
        (var-set governance-council new-council)
        (ok true)))

;; Update governance token stake requirement
(define-public (update-governance-token-stake (new-stake uint))
    (begin
        (asserts! (is-council) ERR-NOT-GOVERNANCE-COUNCIL)
        (asserts! (> new-stake u0) ERR-INVALID-PARAMETER)
        (var-set governance-token-stake new-stake)
        (ok true)))