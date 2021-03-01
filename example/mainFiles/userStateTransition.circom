include "../../node_modules/circomlib/circuits/comparators.circom";
include "../../node_modules/circomlib/circuits/mux1.circom";
include "../lib/hasherPoseidon.circom";
include "../lib/identityCommitment.circom";
include "../lib/incrementalMerkleTree.circom";
include "../lib/modulo.circom";
include "../lib/sparseMerkleTree.circom";
include "../lib/processAttestations.circom";

template epochKeyExist(epoch_tree_depth) {
    signal input identity_nullifier;
    signal input epoch;
    signal input nonce;
    signal input hash_chain_result;
    signal input epoch_tree_root;
    signal input path_elements[epoch_tree_depth][1];
    signal output epoch_key;

    component epochKeyHasher = Hasher5();
    epochKeyHasher.in[0] <== identity_nullifier;
    epochKeyHasher.in[1] <== epoch;
    epochKeyHasher.in[2] <== nonce;
    epochKeyHasher.in[3] <== 0;
    epochKeyHasher.in[4] <== 0;

    signal epkModed;
    // 2.1.2 Mod epoch key
    component modEPK = ModuloTreeDepth(epoch_tree_depth);
    modEPK.dividend <== epochKeyHasher.hash;
    epkModed <== modEPK.remainder;

    // 2.1.6 Check if hash chain of the epoch key exists in epoch tree
    component epk_exists = SMTLeafExists(epoch_tree_depth);
    epk_exists.leaf_index <== epkModed;
    epk_exists.leaf <== hash_chain_result;
    epk_exists.root <== epoch_tree_root;
    for (var i = 0; i < epoch_tree_depth; i++) {
        epk_exists.path_elements[i][0] <== path_elements[i][0];
    }
    epoch_key <== epkModed;
}

template UserStateTransition(GST_tree_depth, epoch_tree_depth, nullifier_tree_depth, user_state_tree_depth, ATTESTATIONS_PER_EPOCH_KEY, EPOCH_KEY_NONCE_PER_EPOCH, TOTAL_NUM_ATTESTATIONS) {
    signal input epoch;

    // User state tree
    // First intermediate root is the user state tree root before processing
    // Last intermediate root is the new user state tree root after processing
    signal private input intermediate_user_state_tree_roots[TOTAL_NUM_ATTESTATIONS + 1];
    // Inputs of old atttestation records
    signal private input old_pos_reps[TOTAL_NUM_ATTESTATIONS];
    signal private input old_neg_reps[TOTAL_NUM_ATTESTATIONS];
    signal private input old_graffities[TOTAL_NUM_ATTESTATIONS];
    signal private input UST_path_elements[TOTAL_NUM_ATTESTATIONS][user_state_tree_depth][1];

    // Global state tree leaf: Identity & user state root
    signal private input identity_pk[2];
    signal private input identity_nullifier;
    signal private input identity_trapdoor;
    // Global state tree
    signal private input GST_path_elements[GST_tree_depth][1];
    signal private input GST_path_index[GST_tree_depth];
    signal input GST_root;

    // Selector is used to determined if the attestation should be processed
    signal private input selectors[TOTAL_NUM_ATTESTATIONS];
    // Inputs of the atttestations
    signal private input attester_ids[TOTAL_NUM_ATTESTATIONS];
    signal private input pos_reps[TOTAL_NUM_ATTESTATIONS];
    signal private input neg_reps[TOTAL_NUM_ATTESTATIONS];
    signal private input graffities[TOTAL_NUM_ATTESTATIONS];
    signal private input overwrite_graffitis[TOTAL_NUM_ATTESTATIONS];

    // Epoch key & epoch tree
    signal private input epk_path_elements[EPOCH_KEY_NONCE_PER_EPOCH][epoch_tree_depth][1];
    signal private input hash_chain_results[EPOCH_KEY_NONCE_PER_EPOCH];
    signal input epoch_tree_root;

    signal output new_GST_leaf;
    // Nullifier of the attestations
    signal output nullifiers[TOTAL_NUM_ATTESTATIONS];
    // Nullifier of epoch keys
    signal output epoch_key_nullifier[EPOCH_KEY_NONCE_PER_EPOCH];

    // Validate config params
    ATTESTATIONS_PER_EPOCH_KEY * EPOCH_KEY_NONCE_PER_EPOCH === TOTAL_NUM_ATTESTATIONS;
    /* 0. Validate inputs */
    for (var i = 0; i < TOTAL_NUM_ATTESTATIONS; i++) {
        selectors[i] * (selectors[i] - 1) === 0
    }
    /* End of check 0 */


    /* 1. Check if user exists in the Global State Tree */
    component identity_commitment = IdentityCommitment();
    identity_commitment.identity_pk[0] <== identity_pk[0];
    identity_commitment.identity_pk[1] <== identity_pk[1];
    identity_commitment.identity_nullifier <== identity_nullifier;
    identity_commitment.identity_trapdoor <== identity_trapdoor;

    component leaf = HashLeftRight();
    leaf.left <== identity_commitment.out;
    // First intermediate root is the user state tree root before processing
    leaf.right <== intermediate_user_state_tree_roots[0];

    component GST_leaf_exists = LeafExists(GST_tree_depth);
    GST_leaf_exists.leaf <== leaf.hash;
    for (var i = 0; i < GST_tree_depth; i++) {
        GST_leaf_exists.path_index[i] <== GST_path_index[i];
        GST_leaf_exists.path_elements[i][0] <== GST_path_elements[i][0];
    }
    GST_leaf_exists.root <== GST_root;
    /* End of check 1 */

    /* 2. Process the attestations of the epoch key specified by nonce `n` and verify attestation nullifiers */
    signal zero_leaf;
    component zero_leaf_hasher = HashLeftRight();
    zero_leaf_hasher.left <== 0;
    zero_leaf_hasher.right <== 0;
    zero_leaf <== zero_leaf_hasher.hash;
    // Leaf of a seen nullifier should have value hashLeftRight(1, 0)
    signal one_leaf;
    component one_leaf_hasher = HashLeftRight();
    one_leaf_hasher.left <== 1;
    one_leaf_hasher.right <== 0;
    one_leaf <== one_leaf_hasher.hash;

    var start_index;
    component epkExist[EPOCH_KEY_NONCE_PER_EPOCH];
    component process_attestations[EPOCH_KEY_NONCE_PER_EPOCH];
    for (var n = 0; n < EPOCH_KEY_NONCE_PER_EPOCH; n++) {
        start_index = n * ATTESTATIONS_PER_EPOCH_KEY;
        epkExist[n] = epochKeyExist(epoch_tree_depth);
        // 2.1 Check if epoch key exists in epoch tree
        epkExist[n].identity_nullifier <== identity_nullifier;
        epkExist[n].epoch <== epoch;
        epkExist[n].nonce <== n;
        epkExist[n].hash_chain_result <== hash_chain_results[n];
        epkExist[n].epoch_tree_root <== epoch_tree_root;
        for (var i = 0; i < epoch_tree_depth; i++) {
            epkExist[n].path_elements[i][0] <== epk_path_elements[n][i][0];
        }

        // 2.2 Begin processing attestations
        process_attestations[n] = ProcessAttestations(nullifier_tree_depth, user_state_tree_depth, ATTESTATIONS_PER_EPOCH_KEY);
        process_attestations[n].epoch <== epoch;
        process_attestations[n].nonce <== n;
        process_attestations[n].identity_nullifier <== identity_nullifier;
        process_attestations[n].epoch_key <== epkExist[n].epoch_key;
        process_attestations[n].hash_chain_result <== hash_chain_results[n];
        process_attestations[n].intermediate_user_state_tree_roots[0] <== intermediate_user_state_tree_roots[start_index + 0];
        for (var i = 0; i < ATTESTATIONS_PER_EPOCH_KEY; i++) {
            process_attestations[n].intermediate_user_state_tree_roots[i + 1] <== intermediate_user_state_tree_roots[start_index + i + 1];
            process_attestations[n].old_pos_reps[i] <== old_pos_reps[start_index + i];
            process_attestations[n].old_neg_reps[i] <== old_neg_reps[start_index + i];
            process_attestations[n].old_graffities[i] <== old_graffities[start_index + i];
            for (var j = 0; j < user_state_tree_depth; j++) {
                process_attestations[n].path_elements[i][j][0] <== UST_path_elements[start_index + i][j][0];
            }
            process_attestations[n].attester_ids[i] <== attester_ids[start_index + i];
            process_attestations[n].pos_reps[i] <== pos_reps[start_index + i];
            process_attestations[n].neg_reps[i] <== neg_reps[start_index + i];
            process_attestations[n].graffities[i] <== graffities[start_index + i];
            process_attestations[n].overwrite_graffitis[i] <== overwrite_graffitis[start_index + i];
            process_attestations[n].selectors[i] <== selectors[start_index + i];
        }

        // 2.3 Output attestations nullifers
        for (var i = 0; i < ATTESTATIONS_PER_EPOCH_KEY; i++) {
            nullifiers[start_index + i] <== process_attestations[n].nullifiers[i];
        }
        // Output epoch key nullifiers
        epoch_key_nullifier[n] <== process_attestations[n].epoch_key_nullifier;
    }
    /* End of 2. process the attestations of the epoch key specified by nonce `n` and verify attestation nullifiers */


    /* 3. Compute and output new GST leaf */
    // 3.1 Compute new GST leaf
    component new_leaf = HashLeftRight();
    new_leaf.left <== identity_commitment.out;
    // Last intermediate root is the new user state tree root
    new_leaf.right <== intermediate_user_state_tree_roots[TOTAL_NUM_ATTESTATIONS];
    new_GST_leaf <== new_leaf.hash;
    /* End of 3. compute and output new GST leaf */
}

component main = UserStateTransition(4, 8, 8, 4, 1, 6, 6);