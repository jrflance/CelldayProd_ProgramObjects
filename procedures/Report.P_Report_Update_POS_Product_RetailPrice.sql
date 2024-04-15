--liquibase formatted sql

--changeset Nicolas Griesdorn 2918bbec stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-11-08
				:
	Description	: SP used in CRM to update the RetailPrice of 1 or multiple Product IDs in the tblRetailDetails table
				:
	NG20240102	: Added new option to Insert Retail Price, added new variable called UPC to go along with the insert.
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Update_POS_Product_RetailPrice]
    (
        @SessionID INT
        , @Option INT
        , @Product_ID AS VARCHAR(250)
        , @RetailPrice FLOAT
        , @UPC CHAR(14) --NG20240102

    )
AS
BEGIN TRY

    IF (ISNULL(@SessionID, '') <> 2)
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF @Option = 0 --View
        BEGIN

            IF
                NOT EXISTS (
                    SELECT rd.ProductID FROM Products.tblRetailDetails AS rd WHERE rd.ProductId IN (SELECT ID FROM dbo.fnSplitter(@Product_ID))
                )
                RAISERROR (
                    'The ProductID entered currently does not exist in this table, please enter either a different Product ID or use the Insert Retail Price option to insert a new Product ID.', -- noqa: LT05
                    12,
                    1
                );

            SELECT
                p.Product_ID
                , p.Name
                , rd.RetailPrice
            FROM Products.tblRetailDetails AS rd
            JOIN dbo.Products AS p
                ON p.Product_ID = rd.ProductID
            WHERE
                p.Product_ID IN
                (
                    SELECT ID FROM dbo.fnSplitter(@Product_ID)
                );
        END;

    IF @Option = 1 --Insert RetailPrice NG20240102
        BEGIN

            IF (ISNULL(@RetailPrice, 0) = 0)
                RAISERROR (
                    'There is currently no Retail Price entered or the Retail Price entered is invalid, please enter a Retail Price and try again.',
                    13,
                    1
                );

            IF (ISNULL(@Product_ID, 0) = 0)
                RAISERROR (
                    'There is currently no Product ID entered or the Product ID entered is invalid, please enter a Product ID and try again.',
                    13,
                    1
                );

            IF (ISNULL(@UPC, '') = '')
                RAISERROR ('There is currently no UPC entered or the UPC entered is invalid, please enter a UPC and try again.', 13, 1);

            IF EXISTS (SELECT rd.ProductID FROM Products.tblRetailDetails AS rd WHERE rd.ProductId IN (SELECT ID FROM dbo.fnSplitter(@Product_ID)))
                RAISERROR (
                    'This Product ID provided is currently already inserted in the table, please use the Update Retail Price to modify this Product.',
                    13,
                    1
                );

            INSERT INTO Products.tblRetailDetails
            (
                ProductId,
                RetailPrice,
                UPC
            )
            VALUES
            (
                @Product_ID,    -- ProductId - int
                @RetailPrice, -- RetailPrice - float
                @UPC    -- UPC - char(14)
            )

            SELECT
                p.Product_ID
                , p.Name
                , rd.RetailPrice
            FROM Products.tblRetailDetails AS rd
            JOIN dbo.Products AS p
                ON p.Product_ID = rd.ProductID
            WHERE
                P.Product_ID IN
                (
                    SELECT ID FROM dbo.fnSplitter(@Product_ID)
                );
        END;
    IF @Option = 2
        BEGIN
            IF (ISNULL(@UPC, '') = '')
                RAISERROR ('There is currently no UPC entered or the UPC entered is invalid, please enter a valid UPC and try again.', 14, 1);

            IF EXISTS (SELECT rd.ProductID FROM Products.tblRetailDetails AS rd WHERE rd.ProductId IN (SELECT ID FROM dbo.fnSplitter(@Product_ID)))
                RAISERROR (
                    'This Product ID provided is currently already inserted in the table, please use the Update Retail Price to modify this Product.',
                    14,
                    1
                );

            IF (ISNULL(@Product_ID, 0) = 0)
                RAISERROR (
                    'There is currently no Product ID entered or the Product ID entered is invalid, please enter a valid Product ID and try again.',
                    14,
                    1
                );

            IF NOT (ISNULL(@RetailPrice, 0) = 0)
                RAISERROR (
                    'There is currently a Retail Price entered on the without Retail Price option, please remove the price or choose the with Price option.', -- noqa: LT05
                    14,
                    1
                )

            INSERT INTO Products.tblRetailDetails
            (
                ProductId,
                RetailPrice,
                UPC
            )
            VALUES
            (
                @Product_ID,    -- ProductId - int
                NULL, -- RetailPrice - float
                @UPC    -- UPC - char(14)
            )

            SELECT
                p.Product_ID
                , p.Name
                , rd.RetailPrice
            FROM Products.tblRetailDetails AS rd
            JOIN dbo.Products AS p
                ON p.Product_ID = rd.ProductID
            WHERE
                P.Product_ID IN
                (
                    SELECT ID FROM dbo.fnSplitter(@Product_ID)
                );
        END;
    IF @Option = 3 --Update RetailPrice
        BEGIN

            IF
                NOT EXISTS (
                    SELECT rd.ProductID FROM Products.tblRetailDetails AS rd WHERE rd.ProductId IN (SELECT ID FROM dbo.fnSplitter(@Product_ID))
                )
                RAISERROR (
                    'The ProductID entered currently does not exist in this table, please enter either a different Product ID or use the Insert Retail Price option to insert a new Product ID.', -- noqa: LT05
                    15,
                    1
                );

            IF (ISNULL(@RetailPrice, 0) = 0)
                RAISERROR (
                    'There is currently no Retail Price entered or the Retail Price entered is invalid, please enter a Retail Price and try again.',
                    15,
                    1
                );

            UPDATE Products.tblRetailDetails
            SET RetailPrice = @RetailPrice
            WHERE ProductID IN (SELECT ID FROM dbo.fnSplitter(@Product_ID));

            SELECT p.Product_ID, p.Name, rd.RetailPrice
            FROM Products.tblRetailDetails AS rd
            JOIN dbo.Products AS p
                ON p.Product_ID = rd.ProductID
            WHERE
                P.Product_ID IN
                (
                    SELECT ID FROM dbo.fnSplitter(@Product_ID)
                );
        END;
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
