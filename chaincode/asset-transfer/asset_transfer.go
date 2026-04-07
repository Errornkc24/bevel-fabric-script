// =============================================================================
// asset_transfer.go - Simple CRUD Chaincode for Hyperledger Fabric 2.x
// =============================================================================
// Manages Assets on the blockchain ledger with full CRUD operations.
// Deployed on mychannel spanning org1 and org2.

package main

import (
	"encoding/json"
	"fmt"
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// SmartContract provides CRUD functions for managing Assets
type SmartContract struct {
	contractapi.Contract
}

// Asset describes an asset stored on the ledger
type Asset struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Owner    string `json:"owner"`
	Value    int    `json:"value"`
	Category string `json:"category"`
	Status   string `json:"status"`
}

// InitLedger pre-populates the ledger with sample assets
func (s *SmartContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
	assets := []Asset{
		{ID: "asset001", Name: "Laptop Pro", Owner: "Alice", Value: 1500, Category: "Electronics", Status: "active"},
		{ID: "asset002", Name: "Office Desk", Owner: "Bob", Value: 800, Category: "Furniture", Status: "active"},
		{ID: "asset003", Name: "Ergonomic Chair", Owner: "Charlie", Value: 450, Category: "Furniture", Status: "active"},
		{ID: "asset004", Name: "4K Monitor", Owner: "Alice", Value: 700, Category: "Electronics", Status: "active"},
		{ID: "asset005", Name: "Server Rack", Owner: "DataCenter", Value: 5000, Category: "Infrastructure", Status: "active"},
	}

	for _, asset := range assets {
		assetJSON, err := json.Marshal(asset)
		if err != nil {
			return fmt.Errorf("failed to marshal asset %s: %v", asset.ID, err)
		}
		if err := ctx.GetStub().PutState(asset.ID, assetJSON); err != nil {
			return fmt.Errorf("failed to put asset %s: %v", asset.ID, err)
		}
	}

	log.Printf("InitLedger: added %d assets to the ledger", len(assets))
	return nil
}

// CreateAsset adds a new asset to the ledger
func (s *SmartContract) CreateAsset(ctx contractapi.TransactionContextInterface, id, name, owner string, value int, category string) error {
	exists, err := s.AssetExists(ctx, id)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("asset %s already exists", id)
	}

	asset := Asset{
		ID:       id,
		Name:     name,
		Owner:    owner,
		Value:    value,
		Category: category,
		Status:   "active",
	}

	assetJSON, err := json.Marshal(asset)
	if err != nil {
		return err
	}

	return ctx.GetStub().PutState(id, assetJSON)
}

// ReadAsset retrieves an asset from the ledger by ID
func (s *SmartContract) ReadAsset(ctx contractapi.TransactionContextInterface, id string) (*Asset, error) {
	assetJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return nil, fmt.Errorf("failed to read asset %s: %v", id, err)
	}
	if assetJSON == nil {
		return nil, fmt.Errorf("asset %s does not exist", id)
	}

	var asset Asset
	if err := json.Unmarshal(assetJSON, &asset); err != nil {
		return nil, err
	}
	return &asset, nil
}

// UpdateAsset updates an existing asset on the ledger
func (s *SmartContract) UpdateAsset(ctx contractapi.TransactionContextInterface, id, name, owner string, value int, category string) error {
	existing, err := s.ReadAsset(ctx, id)
	if err != nil {
		return err
	}

	existing.Name = name
	existing.Owner = owner
	existing.Value = value
	existing.Category = category

	assetJSON, err := json.Marshal(existing)
	if err != nil {
		return err
	}

	return ctx.GetStub().PutState(id, assetJSON)
}

// DeleteAsset removes an asset from the ledger
func (s *SmartContract) DeleteAsset(ctx contractapi.TransactionContextInterface, id string) error {
	exists, err := s.AssetExists(ctx, id)
	if err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("asset %s does not exist", id)
	}

	return ctx.GetStub().DelState(id)
}

// AssetExists checks if an asset exists on the ledger
func (s *SmartContract) AssetExists(ctx contractapi.TransactionContextInterface, id string) (bool, error) {
	assetJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return false, err
	}
	return assetJSON != nil, nil
}

// TransferAsset transfers an asset to a new owner
func (s *SmartContract) TransferAsset(ctx contractapi.TransactionContextInterface, id, newOwner string) error {
	asset, err := s.ReadAsset(ctx, id)
	if err != nil {
		return err
	}

	asset.Owner = newOwner
	assetJSON, err := json.Marshal(asset)
	if err != nil {
		return err
	}

	return ctx.GetStub().PutState(id, assetJSON)
}

// SetAssetStatus updates the status of an asset (active/inactive/maintenance)
func (s *SmartContract) SetAssetStatus(ctx contractapi.TransactionContextInterface, id, status string) error {
	asset, err := s.ReadAsset(ctx, id)
	if err != nil {
		return err
	}

	asset.Status = status
	assetJSON, err := json.Marshal(asset)
	if err != nil {
		return err
	}

	return ctx.GetStub().PutState(id, assetJSON)
}

// GetAllAssets returns all assets on the ledger
func (s *SmartContract) GetAllAssets(ctx contractapi.TransactionContextInterface) ([]*Asset, error) {
	resultsIterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return nil, err
	}
	defer resultsIterator.Close()

	var assets []*Asset
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			return nil, err
		}
		var asset Asset
		if err := json.Unmarshal(queryResponse.Value, &asset); err != nil {
			return nil, err
		}
		assets = append(assets, &asset)
	}
	return assets, nil
}

func main() {
	chaincode, err := contractapi.NewChaincode(&SmartContract{})
	if err != nil {
		log.Panicf("Error creating asset-transfer chaincode: %v", err)
	}
	if err := chaincode.Start(); err != nil {
		log.Panicf("Error starting asset-transfer chaincode: %v", err)
	}
}
