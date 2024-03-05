--liquibase formatted sql

--changeset  BrandonStahl:c1a2549c-5a1e-4a7f-a5c7-666f8987e7cd stripComments:false runOnChange:true splitStatements:false

--=============================================
--				:
--	Author		: Brandon Stahl
--				:
--	Created		: 2024-02-19
--				:
--	Description	: Returns appened catalog for multiple accounts.
--              : If products differ between accounts they will show twice.
--				:
--	Test Data   : DECLARE AccountIds dbo.Ids INSERT INTO @AccountIds VALUES (13379)
--=============================================
CREATE OR ALTER PROCEDURE [Report].[P_GetMultiAccountCatalog]
    (
        @AccountIds dbo.IDS READONLY
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @AccountId INT,
        @ExcludedProductTypes dbo.IDS,
        @CarrierAttributeId INT = 5,
        @MultiBrandCarrier VARCHAR(100) = 'Multi-Brand',
        @HandsetBrandedSubTypeId INT = 2,
        @KittedBrandedSubTypeId INT = 3,
        @SimMpSubTypeId INT = 5,
        @HandsetMpSubTypeId INT = 6,
        @KittedMpSubTypeId INT = 7

    INSERT @ExcludedProductTypes VALUES (4), (5), (8), (9), (13), (19)

    IF OBJECT_ID('tempdb..#Results') IS NOT NULL
        BEGIN
            DROP TABLE #Results;
        END;

    CREATE TABLE #Results
    (
        SKU INT,
        ProductId INT,
        [Name] VARCHAR(MAX),
        SalePrice DECIMAL(7, 2),
        Cost DECIMAL(7, 2),
        UPC CHAR(14),
        ProductType VARCHAR(30),
        SubProductType VARCHAR(100),
        Tags VARCHAR(MAX),
        IsSerialized BIT
    );

    IF OBJECT_ID('tempdb..#Catalog') IS NOT NULL
        BEGIN
            DROP TABLE #Catalog;
        END;

    CREATE TABLE #Catalog
    (
        ProductId INT NOT NULL,
        Lev INT,
        [Name] NVARCHAR(MAX),
        ParentID INT,
        LinkedProd INT,
        ProductType INT,
        SmImage NVARCHAR(100),
        LgImage NVARCHAR(100),
        BasePrice DECIMAL(7, 2),
        Discount DECIMAL(7, 2),
        IsAmount BIT,
        [Priority] INT,
        [Description] NTEXT,
        Color NVARCHAR(10),
        LongDesc NTEXT,
        ShortDesc NTEXT,
        NumOfAddons INT,
        DynamicRate BIT,
        IsByop BIT,
        ProductRating DECIMAL(3, 2),
        Last90DaysSales INT,
        ProductVendorId INT,
        ProductVendorName NVARCHAR(50),
        KeyWords NVARCHAR(255),
        SubProductTypeId SMALLINT,
        INDEX IX_Catalog NONCLUSTERED (ProductId)
    )
    BEGIN TRY
        DECLARE account_cursor CURSOR LOCAL FORWARD_ONLY READ_ONLY
        FOR SELECT a.ID
        FROM @AccountIds AS a;

        OPEN account_cursor

        FETCH NEXT FROM account_cursor
        INTO @AccountId;

        WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT INTO #Catalog
                EXEC Products.P_GetProductListByCategory_v6
                    @accountID = @AccountId,
                    @categoryID = 0,
                    @Direct = 0,
                    @Platform = NULL

                FETCH NEXT FROM account_cursor
                INTO @AccountId;
            END
        CLOSE account_cursor;
        DEALLOCATE account_cursor;

        IF OBJECT_ID('tempdb..#ProductInfo') IS NOT NULL
            BEGIN
                DROP TABLE #ProductInfo;
            END;

        SELECT
            p.Product_ID,
            pt.ProductTypeName AS ProductType,
            spt.[Name] AS SubProductType,
            ISNULL(pt.ProductTypeID, 0) AS ProductTypeId,
            ISNULL(spt.SubProductTypeId, 0) AS SubProductTypeId
        INTO #ProductInfo
        FROM dbo.Products AS p
        JOIN Products.tblProductType AS pt ON pt.ProductTypeID = ISNULL(p.Product_Type, 0)
        LEFT JOIN Products.tblSubProductType AS spt ON spt.SubProductTypeId = p.SubProductTypeId
        WHERE EXISTS (SELECT 1 FROM #Catalog AS c WHERE p.Product_ID = c.ProductId);

        IF OBJECT_ID('tempdb..#ProductCarriers') IS NOT NULL
            BEGIN
                DROP TABLE #ProductCarriers;
            END;

        SELECT
            pcm.ProductId,
            c.Carrier_Name
        INTO #ProductCarriers
        FROM Products.tblProductCarrierMapping AS pcm
        JOIN dbo.Carrier_ID AS c ON pcm.CarrierId = c.ID
        WHERE EXISTS (SELECT 1 FROM #ProductInfo AS p WHERE p.Product_ID = pcm.ProductId);

        IF OBJECT_ID('tempdb..#MultiCarrier') IS NOT NULL
            BEGIN
                DROP TABLE #MultiCarrier;
            END;

        SELECT
            pc.ProductId,
            STRING_AGG(pa.Value, ',')
            WITHIN GROUP (ORDER BY pa.Value) AS Carrier_Name
        INTO #MultiCarrier
        FROM #ProductCarriers AS pc
        JOIN MarketPlace.tblProductAttributes AS pa ON pc.ProductId = pa.Product_ID
        JOIN MarketPlace.tblAttributes AS a ON a.AttributeID = pa.AttributeID
        WHERE
            pc.Carrier_Name = @MultiBrandCarrier
            AND a.AttributeID = @CarrierAttributeId
        GROUP BY pc.ProductId

        IF OBJECT_ID('tempdb..#UPC') IS NOT NULL
            BEGIN
                DROP TABLE #UPC;
            END;

        SELECT DISTINCT
            rd.ProductId,
            rd.UPC
        INTO #UPC
        FROM Products.tblRetailDetails AS rd
        JOIN #Catalog AS c ON c.ProductId = rd.ProductId;


        INSERT INTO #Results
        (
            SKU,
            ProductId,
            [Name],
            SalePrice,
            Cost,
            UPC,
            ProductType,
            SubProductType,
            Tags,
            IsSerialized
        )
        SELECT DISTINCT
            c.ProductId AS SKU,
            c.ProductId,
            c.[Name],
            c.BasePrice,
            CASE
                WHEN c.IsAmount = 1 THEN c.BasePrice - c.Discount
                ELSE CAST(ROUND(c.BasePrice - c.BasePrice * c.Discount / 100, 2) AS DECIMAL(7, 2))
            END AS Cost,
            ISNULL(u.UPC, '') AS UPC,
            p.ProductType,
            ISNULL(p.SubProductType, '') AS SubProductType,
            ISNULL(mc.Carrier_Name, ISNULL(pc.Carrier_Name, '')) AS CarrierName,
            IIF(
                p.SubProductTypeId = @HandsetBrandedSubTypeId
                OR p.SubProductTypeId = @KittedBrandedSubTypeId
                OR p.SubProductTypeId = @HandsetMpSubTypeId
                OR p.SubProductTypeId = @SimMpSubTypeId
                OR p.SubProductTypeId = @KittedMpSubTypeId,
                1, 0
            ) AS IsSerialized
        FROM #Catalog AS c
        JOIN #ProductInfo AS p ON c.ProductId = p.Product_ID
        LEFT JOIN #ProductCarriers AS pc ON pc.ProductId = c.ProductId
        LEFT JOIN #MultiCarrier AS mc ON mc.ProductId = c.ProductId
        LEFT JOIN #UPC AS u ON u.ProductId = c.ProductId
        WHERE NOT EXISTS (SELECT 1 FROM @ExcludedProductTypes AS ept WHERE ept.Id = p.ProductTypeId);

        SELECT
            SKU,
            ProductId,
            [Name],
            SalePrice,
            Cost,
            UPC,
            ProductType,
            SubProductType,
            Tags,
            IsSerialized
        FROM #Results;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'account_cursor') >= -1
            BEGIN
                CLOSE account_cursor;
                DEALLOCATE account_cursor;
            END;
        THROW;
    END CATCH;
END;
