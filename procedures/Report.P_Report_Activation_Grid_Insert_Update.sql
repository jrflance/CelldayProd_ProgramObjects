--liquibase formatted sql

--changeset Nicolas Griesdorn 0ab94dd3 stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-06-23
				:
	Description	: SP used in CRM to insert new Products into the Activation Grid
				:
	NG20240402	: Refactor of report to allow changes to the following table: Products.tblIndirectRatePlanResidual
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Activation_Grid_Insert_Update]
    (
        @SessionID INT
        , @Option INT
        , @ProductID INT
        , @CarrierID INT
        , @Amount NVARCHAR(MAX)
        , @DealerCommissionSubTypeID INT
        , @TierCode VARCHAR(MAX)
        , @StartDate DATETIME
        , @EndDate DATETIME
    )
AS
BEGIN TRY

    IF ISNULL(@SessionID, 0) <> 2
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF @Option = 0 --View Spiff
        BEGIN
            SELECT
                irp.ProductId AS [Product ID]
                , p.Name AS [Plan Name]
                , irp.StartDate
                , irp.EndDate
                , ttc.TierName
                , CASE
                    WHEN dcs.Name = '1st Month Spiff' AND irp.DealerCommissionSubTypeId = 5 THEN '1st Month Port-In Spiff'
                    WHEN dcs.Name = '2nd Month Spiff' AND irp.DealerCommissionSubTypeId = 6 THEN '2nd Month Port-In Spiff'
                    WHEN dcs.Name = '3rd Month Spiff' AND irp.DealerCommissionSubTypeId = 7 THEN '3rd Month Port-In Spiff'
                    WHEN dcs.Name = '4th Month Spiff' AND irp.DealerCommissionSubTypeId = 8 THEN '4th Month Port-In Spiff'
                    ELSE dcs.Name
                END AS [Spiff Type]
                , CASE
                    WHEN dcs.DealerCommissionTypeId <> 3 THEN CONCAT('$', @Amount) --Non-Residual Amounts
                    WHEN dcs.DealerCommissionTypeId = 3 THEN CONCAT(@Amount, '%') --Residual Amounts
                END AS [Amount]
            FROM Products.tblIndirectRatePlanSpiff AS irp
            JOIN dbo.Products AS p ON irp.ProductId = p.Product_ID
            JOIN Products.tblDealerCommissionSubType AS dcs ON dcs.DealerCommissionSubTypeId = irp.DealerCommissionSubTypeId
            LEFT JOIN tracfone.tblTierCode AS ttc ON ttc.TierCode = irp.TierCode
            WHERE irp.ProductId = @ProductID
            GROUP BY
                irp.DealerCommissionSubTypeId,
                irp.ProductId,
                p.Name,
                irp.StartDate,
                irp.EndDate,
                ttc.TierName,
                dcs.Name,
                dcs.DealerCommissionTypeID,
                irp.Amount
            ORDER BY irp.EndDate DESC

        END;

    IF @Option = 1 --View Residual
        BEGIN
            SELECT
                irr.TierCode
                , irr.Amount
                , irr.StartDate
                , irr.EndDate
                , dcs.Name AS [Dealer Commission SubType]
                , ci.Carrier_Name AS [Carrier Name]
            FROM Products.tblIndirectRatePlanResidual AS irr
            JOIN Products.tblDealerCommissionSubType AS dcs ON dcs.DealerCommissionSubTypeId = irr.DealerCommissionSubTypeId
            LEFT JOIN tracfone.tblTierCode AS ttc ON ttc.TierCode = irr.TierCode
            JOIN dbo.Carrier_ID AS ci ON ci.ID = irr.CarrierId
            WHERE irr.CarrierId = @CarrierID
        END;

    IF @Option = 2 --Non-Residuals
        BEGIN

            IF ISNULL(@Amount, '') = ''
                RAISERROR ('The Amount field cannot be left blank, please provide a valid Amount and try again.', 12, 1);

            IF ISNULL(@StartDate, '') = ''
                RAISERROR ('The Start Date field cannot be left blank, please provide a valid Start Date and try again.', 12, 1);

            IF ISNULL(@EndDate, '') = ''
                RAISERROR ('The End Date field cannot be left blank, please provide a valid End Date and try again.', 12, 1);

            IF @DealerCommissionSubTypeID IN (9, 10, 11, 12, 16, 17)
                BEGIN

                    IF
                        EXISTS (
                            SELECT *
                            FROM Products.tblIndirectRatePlanResidual
                            WHERE CarrierId = @CarrierID AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID AND EndDate >= GETDATE()
                        )
                        BEGIN
                            -- Update All Non-Tier Coded Records where DealerCommissionSubTypeID matches
                            UPDATE Products.tblIndirectRatePlanResidual
                            SET EndDate = @StartDate
                            WHERE
                                CarrierId = @CarrierID
                                AND @DealerCommissionSubTypeID = DealerCommissionSubTypeID
                                AND EndDate > @StartDate
                                AND TierCode IS NULL

                            -- Update All Tier Coded Records where DealerCommissionSubTypeID and Tier Code entered matches
                            UPDATE Products.tblIndirectRatePlanResidual
                            SET EndDate = @StartDate
                            WHERE
                                CarrierId = @CarrierID
                                AND @DealerCommissionSubTypeID = DealerCommissionSubTypeID
                                AND EndDate > @StartDate
                                AND TierCode = @TierCode
                        END;

                    IF @TierCode = ''
                        BEGIN
                            INSERT INTO Products.tblIndirectRatePlanResidual
                            (
                                TierCode,
                                Amount,
                                StartDate,
                                EndDate,
                                DealerCommissionSubTypeId,
                                CarrierId
                            )
                            VALUES
                            (
                                NULL,      -- TierCode - varchar(10)
                                CAST(@Amount AS DECIMAL(5, 2)),      -- Amount - decimal(5, 2)
                                @StartDate, -- StartDate - datetime
                                @EndDate, -- EndDate - datetime
                                @DealerCommissionSubTypeID,         -- DealerCommissionSubTypeId - tinyint
                                @CarrierID          -- CarrierId - smallint
                            )
                        END;

                    IF @TierCode <> ''
                        BEGIN
                            INSERT INTO Products.tblIndirectRatePlanResidual
                            (
                                TierCode,
                                Amount,
                                StartDate,
                                EndDate,
                                DealerCommissionSubTypeId,
                                CarrierId
                            )
                            VALUES
                            (
                                @TierCode,      -- TierCode - varchar(10)
                                CAST(@Amount AS DECIMAL(5, 2)),      -- Amount - decimal(5, 2)
                                @StartDate, -- StartDate - datetime
                                @EndDate, -- EndDate - datetime
                                @DealerCommissionSubTypeID,         -- DealerCommissionSubTypeId - tinyint
                                @CarrierID          -- CarrierId - smallint
                            )

                        END;

                    SELECT
                        irr.TierCode
                        , irr.Amount
                        , irr.StartDate
                        , irr.EndDate
                        , dcs.Name AS [Dealer Commission SubType]
                        , ci.Carrier_Name AS [Carrier Name]
                    FROM Products.tblIndirectRatePlanResidual AS irr
                    JOIN Products.tblDealerCommissionSubType AS dcs ON dcs.DealerCommissionSubTypeId = irr.DealerCommissionSubTypeId
                    LEFT JOIN tracfone.tblTierCode AS ttc ON ttc.TierCode = irr.TierCode
                    JOIN dbo.Carrier_ID AS ci ON ci.ID = irr.CarrierId
                    WHERE irr.DealerCommissionSubTypeId = @DealerCommissionSubTypeID AND irr.CarrierId = @CarrierID

                END;

            IF @DealerCommissionSubTypeID NOT IN (9, 10, 11, 12, 16, 17)
                BEGIN

                    IF EXISTS (SELECT * FROM Products.tblIndirectRatePlanSpiff WHERE ProductId = @ProductID AND EndDate >= GETDATE())
                        BEGIN
                            -- Update All Non-Tier Coded Records where DealerCommissionSubTypeID matches
                            UPDATE Products.tblIndirectRatePlanSpiff
                            SET EndDate = @StartDate
                            WHERE
                                ProductID = @ProductID
                                AND @DealerCommissionSubTypeID = DealerCommissionSubTypeID
                                AND EndDate > @StartDate
                                AND TierCode IS NULL

                            -- Update All Tier Coded Records where DealerCommissionSubTypeID and Tier Code entered matches
                            UPDATE Products.tblIndirectRatePlanSpiff
                            SET EndDate = @StartDate
                            WHERE
                                ProductID = @ProductID
                                AND @DealerCommissionSubTypeID = DealerCommissionSubTypeID
                                AND EndDate > @StartDate
                                AND TierCode = @TierCode
                        END;

                    INSERT INTO Products.tblIndirectRatePlanSpiff
                    (
                        TierCode,
                        Amount,
                        StartDate,
                        EndDate,
                        DealerCommissionSubTypeId,
                        ProductId
                    )

                    VALUES
                    -- Start of Activation Spiff
                    (@TierCode, CAST(@Amount AS DECIMAL(5, 2)), @StartDate, @EndDate, @DealerCommissionSubTypeID, @ProductID)

                    SELECT
                        irp.ProductId AS [Product ID]
                        , p.Name AS [Plan Name]
                        , irp.StartDate
                        , irp.EndDate
                        , ttc.TierName
                        , CASE
                            WHEN dcs.Name = '1st Month Spiff' AND irp.DealerCommissionSubTypeId = 5 THEN '1st Month Port-In Spiff'
                            WHEN dcs.Name = '2nd Month Spiff' AND irp.DealerCommissionSubTypeId = 6 THEN '2nd Month Port-In Spiff'
                            WHEN dcs.Name = '3rd Month Spiff' AND irp.DealerCommissionSubTypeId = 7 THEN '3rd Month Port-In Spiff'
                            WHEN dcs.Name = '4th Month Spiff' AND irp.DealerCommissionSubTypeId = 8 THEN '4th Month Port-In Spiff'
                            ELSE dcs.Name
                        END AS [Spiff Type]
                        , CASE
                            WHEN dcs.DealerCommissionTypeId <> 3 THEN CONCAT('$', @Amount) --Non-Residual Amounts
                            WHEN dcs.DealerCommissionTypeId = 3 THEN CONCAT(@Amount, '%') --Residual Amounts
                        END AS [Amount]
                    FROM Products.tblIndirectRatePlanSpiff AS irp
                    JOIN dbo.Products AS p ON irp.ProductId = p.Product_ID
                    JOIN Products.tblDealerCommissionSubType AS dcs ON dcs.DealerCommissionSubTypeId = irp.DealerCommissionSubTypeId
                    LEFT JOIN tracfone.tblTierCode AS ttc ON ttc.TierCode = irp.TierCode
                    WHERE irp.ProductId = @ProductID
                    GROUP BY
                        irp.DealerCommissionSubTypeId,
                        irp.ProductId,
                        p.Name,
                        irp.StartDate,
                        irp.EndDate,
                        ttc.TierName,
                        dcs.Name,
                        dcs.DealerCommissionTypeID,
                        irp.Amount
                    ORDER BY irp.EndDate DESC
                END;
        END;


    IF @Option = 3 --Delete Non-Residuals
        BEGIN
            IF ISNULL(@StartDate, '') = ''
                RAISERROR ('The Start Date field cannot be left blank, please provide a valid Start Date and try again.', 12, 1);

            IF ISNULL(@EndDate, '') = ''
                RAISERROR ('The End Date field cannot be left blank, please provide a valid End Date and try again.', 12, 1);

            IF @DealerCommissionSubTypeID IN (9, 10, 11, 12, 16, 17)
                BEGIN

                    IF
                        EXISTS (
                            SELECT *
                            FROM Products.tblIndirectRatePlanResidual
                            WHERE
                                CarrierId = @CarrierID
                                AND StartDate = @StartDate
                                AND EndDate = @EndDate
                                AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                                AND TierCode IS NULL
                        )
                        DELETE FROM Products.tblIndirectRatePlanResidual
                        WHERE
                            CarrierId = @CarrierID
                            AND StartDate = @StartDate
                            AND EndDate = @EndDate
                            AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                            AND TierCode IS NULL

                    IF
                        EXISTS (
                            SELECT *
                            FROM Products.tblIndirectRatePlanResidual
                            WHERE
                                CarrierId = @CarrierID
                                AND StartDate = @StartDate
                                AND EndDate = @EndDate
                                AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                                AND TierCode = @TierCode
                        )
                        DELETE FROM Products.tblIndirectRatePlanResidual
                        WHERE
                            CarrierId = @CarrierID
                            AND StartDate = @StartDate
                            AND EndDate = @EndDate
                            AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                            AND TierCode = @TierCode



                    SELECT
                        irr.TierCode
                        , irr.Amount
                        , irr.StartDate
                        , irr.EndDate
                        , dcs.Name AS [Dealer Commission SubType]
                        , ci.Carrier_Name AS [Carrier Name]
                    FROM Products.tblIndirectRatePlanResidual AS irr
                    JOIN Products.tblDealerCommissionSubType AS dcs ON dcs.DealerCommissionSubTypeId = irr.DealerCommissionSubTypeId
                    LEFT JOIN tracfone.tblTierCode AS ttc ON ttc.TierCode = irr.TierCode
                    JOIN dbo.Carrier_ID AS ci ON ci.ID = irr.CarrierId
                    WHERE irr.DealerCommissionSubTypeId = @DealerCommissionSubTypeID AND irr.CarrierId = @CarrierID
                END;


            IF @DealerCommissionSubTypeID NOT IN (9, 10, 11, 12, 16, 17)
                BEGIN

                    IF
                        EXISTS (
                            SELECT *
                            FROM Products.tblIndirectRatePlanSpiff
                            WHERE
                                ProductId = @ProductID
                                AND StartDate = @StartDate
                                AND EndDate = @EndDate
                                AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                                AND TierCode IS NULL
                        )
                        DELETE FROM Products.tblIndirectRatePlanSpiff
                        WHERE
                            ProductId = @ProductID
                            AND StartDate = @StartDate
                            AND EndDate = @EndDate
                            AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                            AND TierCode IS NULL

                    IF
                        EXISTS (
                            SELECT *
                            FROM Products.tblIndirectRatePlanSpiff
                            WHERE
                                ProductId = @ProductID
                                AND StartDate = @StartDate
                                AND EndDate = @EndDate
                                AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                                AND TierCode = @TierCode
                        )
                        DELETE FROM Products.tblIndirectRatePlanSpiff
                        WHERE
                            ProductId = @ProductID
                            AND StartDate = @StartDate
                            AND EndDate = @EndDate
                            AND DealerCommissionSubTypeId = @DealerCommissionSubTypeID
                            AND TierCode = @TierCode

                    SELECT
                        irp.ProductId AS [Product ID]
                        , p.Name AS [Plan Name]
                        , irp.StartDate
                        , irp.EndDate
                        , ttc.TierName
                        , CASE
                            WHEN dcs.Name = '1st Month Spiff' AND irp.DealerCommissionSubTypeId = 5 THEN '1st Month Port-In Spiff'
                            WHEN dcs.Name = '2nd Month Spiff' AND irp.DealerCommissionSubTypeId = 6 THEN '2nd Month Port-In Spiff'
                            WHEN dcs.Name = '3rd Month Spiff' AND irp.DealerCommissionSubTypeId = 7 THEN '3rd Month Port-In Spiff'
                            WHEN dcs.Name = '4th Month Spiff' AND irp.DealerCommissionSubTypeId = 8 THEN '4th Month Port-In Spiff'
                            ELSE dcs.Name
                        END AS [Spiff Type]
                        , CASE
                            WHEN dcs.DealerCommissionTypeId <> 3 THEN CONCAT('$', @Amount) --Non-Residual Amounts
                            WHEN dcs.DealerCommissionTypeId = 3 THEN CONCAT(@Amount, '%') --Residual Amounts
                        END AS [Amount]
                    FROM Products.tblIndirectRatePlanSpiff AS irp
                    JOIN dbo.Products AS p ON irp.ProductId = p.Product_ID
                    JOIN Products.tblDealerCommissionSubType AS dcs ON dcs.DealerCommissionSubTypeId = irp.DealerCommissionSubTypeId
                    LEFT JOIN tracfone.tblTierCode AS ttc ON ttc.TierCode = irp.TierCode
                    WHERE irp.ProductId = @ProductID
                    GROUP BY
                        irp.DealerCommissionSubTypeId,
                        irp.ProductId,
                        p.Name,
                        irp.StartDate,
                        irp.EndDate,
                        ttc.TierName,
                        dcs.Name,
                        dcs.DealerCommissionTypeID,
                        irp.Amount
                    ORDER BY irp.EndDate DESC

                END;
        END;

END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
