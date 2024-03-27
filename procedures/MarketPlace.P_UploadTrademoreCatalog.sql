--liquibase formatted sql

--changeset Brandon Stahl/Business Solutions:c81b594c-5540-4b2d-833b-4acd4827cb00 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2023-07-21
--
--IMPACTED DATABASE NAME: CellDay_Prod, Cellday_Temp
--IMPACTED SCHEMA NAME(S): dbo, Marketplace, Upload
--IMPACTED TABLE NAME(S): MarketPlace.tblTradeInPricing, Upload.tblTrademoreCatalogFeed,  dbo.tblAddonDropdownContents
--PURPOSE
--    Report is used to refresh the trade in pricing estimations from Trademore.
--
-- BS20231109: Updated to Not include NA unless null in file and removed OEM drop-down.
-- BS20240201: Allow null or empty columns.
-- =============================================
CREATE OR ALTER PROCEDURE [MarketPlace].[P_UploadTrademoreCatalog]
    (@FileID INT)
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        BEGIN TRANSACTION;

        DECLARE
            @BrandTypeId INT = 367,
            @ModelTypeId INT = 368,
            @CarrierTypeId INT = 369,
            @CapacityTypeId INT = 370,
            @ColorTypeId INT = 371,
            @TradeInProgramId INT = 2,
            @FileTypeId INT = 25;

        DECLARE
            @Delimiter VARCHAR(8) =
            (
                SELECT u.Delimiter
                FROM upload.tblFileType AS u
                WHERE u.FileTypeID = @FileTypeId
            );

        DELETE tip
        FROM MarketPlace.tblTradeInPricing AS tip
        WHERE tip.TradeInProgramId = @TradeInProgramId;

        INSERT INTO MarketPlace.tblTradeInPricing
        (
            TradeInProgramId,
            Brand,
            Model,
            MinPrice,
            MaxPrice,
            [Date],
            Carrier,
            Capacity,
            Color,
            OEMModel
        )
        SELECT
            @TradeInProgramId AS TradeInProgramId,
            A.Chr3 AS MAKE,
            A.Chr5 AS MODEL_NAME,
            ISNULL(TRY_CAST(A.Chr12 AS DECIMAL(8, 2)), 0) AS MinPrice,         --BS20240201
            ISNULL(TRY_CAST(A.Chr12 AS DECIMAL(8, 2)), 0) AS MaxPrice,         --BS20240201
            ISNULL(TRY_CAST(A.Chr13 AS DATETIME), GETDATE()) AS TM_EFFECTIVE_DATE, --BS20240201
            A.Chr2 AS CARRIER,
            A.Chr8 AS MEMORY,
            A.Chr9 AS DEVICE_COLOR,
            A.Chr6 AS OEM_MODEL
        FROM upload.tblPlainText AS t
        CROSS APPLY dbo.SplitText(t.txt, @Delimiter, '"') AS A
        WHERE
            t.fileid = @FileID
            AND ISNULL(A.Chr1, '') != 'ITEM_ID';

        IF OBJECT_ID('tempdb..#Brands') IS NOT NULL
            BEGIN
                DROP TABLE #Brands;
            END;
        SELECT DISTINCT
            tip.Brand
        INTO #Brands
        FROM MarketPlace.tblTradeInPricing AS tip
        WHERE tip.TradeInProgramId = @TradeInProgramId;

        IF OBJECT_ID('tempdb..#Models') IS NOT NULL
            BEGIN
                DROP TABLE #Models;
            END;
        SELECT DISTINCT
            tip.Model
        INTO #Models
        FROM MarketPlace.tblTradeInPricing AS tip
        WHERE tip.TradeInProgramId = @TradeInProgramId;

        IF OBJECT_ID('tempdb..#Carriers') IS NOT NULL
            BEGIN
                DROP TABLE #Carriers;
            END;
        SELECT DISTINCT
            tip.Carrier
        INTO #Carriers
        FROM MarketPlace.tblTradeInPricing AS tip
        WHERE tip.TradeInProgramId = @TradeInProgramId;

        IF OBJECT_ID('tempdb..#Capacities') IS NOT NULL
            BEGIN
                DROP TABLE #Capacities;
            END;
        SELECT DISTINCT
            tip.Capacity
        INTO #Capacities
        FROM MarketPlace.tblTradeInPricing AS tip
        WHERE tip.TradeInProgramId = @TradeInProgramId;

        IF OBJECT_ID('tempdb..#Colors') IS NOT NULL
            BEGIN
                DROP TABLE #Colors;
            END;
        SELECT DISTINCT
            tip.Color
        INTO #Colors
        FROM MarketPlace.tblTradeInPricing AS tip
        WHERE tip.TradeInProgramId = @TradeInProgramId;

        --BS20231109
        DECLARE
            @BrandDropdowns VARCHAR(MAX) =
            (
                SELECT STRING_AGG(ISNULL(b.Brand, 'NA'), '^') WITHIN GROUP (ORDER BY b.Brand) AS Result
                FROM #Brands AS b
            ),
            @ModelDropdowns VARCHAR(MAX) =
            (
                SELECT STRING_AGG(ISNULL(m.Model, 'NA'), '^') WITHIN GROUP (ORDER BY m.Model) AS Result
                FROM #Models AS m
            ),
            @CarrierDropdowns VARCHAR(MAX) =
            (
                SELECT STRING_AGG(ISNULL(c.Carrier, 'NA'), '^') WITHIN GROUP (ORDER BY c.Carrier) AS Result
                FROM #Carriers AS c
            ),
            @CapacityDropdowns VARCHAR(MAX) =
            (
                SELECT STRING_AGG(ISNULL(c.Capacity, 'NA'), '^') WITHIN GROUP (ORDER BY c.Capacity) AS Result
                FROM #Capacities AS c
            ),
            @ColorDropdowns VARCHAR(MAX) =
            (
                SELECT STRING_AGG(ISNULL(c.Color, 'NA'), '^') WITHIN GROUP (ORDER BY c.Color) AS Result
                FROM #Colors AS c
            );

        UPDATE adc
        SET
            adc.Display = CASE
                WHEN adc.AddonID = @BrandTypeId
                    THEN
                        @BrandDropdowns
                WHEN adc.AddonID = @ModelTypeId
                    THEN
                        @ModelDropdowns
                WHEN adc.AddonID = @CarrierTypeId
                    THEN
                        @CarrierDropdowns
                WHEN adc.AddonID = @CapacityTypeId
                    THEN
                        @CapacityDropdowns
                WHEN adc.AddonID = @ColorTypeId THEN
                    @ColorDropdowns
            END,
            adc.[VALUE] = CASE
                WHEN adc.AddonID = @BrandTypeId
                    THEN
                        @BrandDropdowns
                WHEN adc.AddonID = @ModelTypeId
                    THEN
                        @ModelDropdowns
                WHEN adc.AddonID = @CarrierTypeId
                    THEN
                        @CarrierDropdowns
                WHEN adc.AddonID = @CapacityTypeId
                    THEN
                        @CapacityDropdowns
                WHEN adc.AddonID = @ColorTypeId THEN
                    @ColorDropdowns
            END
        FROM dbo.tblAddonDropdownContents AS adc
        WHERE adc.AddonID IN (
            @BrandTypeId, @ModelTypeId, @CarrierTypeId, @CapacityTypeId, @ColorTypeId
        );

        UPDATE f
        SET f.FileStatus = 1
        FROM upload.tblFile AS f
        WHERE f.FileID = @FileID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION;

        UPDATE f
        SET
            f.FileStatus = -1,
            f.ErrorInfo = ERROR_MESSAGE()
        FROM upload.tblFile AS f
        WHERE f.FileID = @FileID;

        THROW;
    END CATCH;
END;
