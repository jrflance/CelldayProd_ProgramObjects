--liquibase formatted sql

--changeset Nicolas Griesdorn 502ee77a stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-10-03
				:
	Description	: SP used in CRM to display number of orders and accounts affected by an outage (Internal or External outages)
				:
	NG20240423	: Redeveloped the report to add ParentItemID
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Number_Of_Orders_Affected_By_Outage]
    (
        @SessionID INT
        , @StartDate DATETIME
        , @EndDate DATETIME
        , @Carrier INT --4 Simple Mobile | 292 TBV | 7 Verizon
        , @OrderType NVARCHAR(25) -- 0 Activations | 1 Top-Ups
    )
AS
BEGIN
    BEGIN TRY
        IF ISNULL(@SessionID, 0) <> 2
            RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

        DROP TABLE IF EXISTS #PreviousWeekTXNs
        DROP TABLE IF EXISTS #CurrentDateTXNs

        IF @OrderType = 0 --Activations
            BEGIN
                (
                    SELECT
                        dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0) AS TimeStampHour,
                        COUNT(o.Order_No) AS [Number Of Order Occurances],
                        COUNT(DISTINCT a.Account_ID) AS [AccountID]
                    INTO #PreviousWeekTXNs
                    FROM dbo.Order_No AS o
                    JOIN dbo.Account AS a
                        ON a.Account_ID = o.Account_ID
                    JOIN dbo.Orders AS o1
                        ON o1.Order_No = o.Order_No
                    JOIN Products.tblProductCarrierMapping AS pcm
                        ON o1.Product_ID = pcm.ProductId
                    WHERE
                        pcm.CarrierId IN (@Carrier)
                        AND o.DateOrdered >= DATEADD(DAY, -14, @StartDate) AND o.DateOrdered <= DATEADD(DAY, -14, @EndDate)
                        AND o.OrderType_ID IN (22, 23)
                        AND ISNULL(o1.ParentItemID, 0) IN (0, 1) --NG20240423
                        AND o.Process = 1
                        AND o.Filled = 1
                        AND o.Void = 0
                    GROUP BY dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0)
                )

                (
                    SELECT
                        dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0) AS TimeStampHour,
                        COUNT(o.Order_No) AS [Number Of Order Occurances],
                        COUNT(DISTINCT a.Account_ID) AS [AccountID]
                    INTO #CurrentDateTXNs
                    FROM dbo.Order_No AS o
                    JOIN dbo.Account AS a
                        ON a.Account_ID = o.Account_ID
                    JOIN dbo.Orders AS o1
                        ON o1.Order_No = o.Order_No
                    JOIN Products.tblProductCarrierMapping AS pcm
                        ON o1.Product_ID = pcm.ProductId
                    WHERE
                        pcm.CarrierId IN (@Carrier)
                        AND o.DateOrdered >= @StartDate AND o.DateOrdered <= @EndDate
                        AND o.OrderType_ID IN (22, 23)
                        AND ISNULL(o1.ParentItemID, 0) IN (0, 1) --NG20240423
                        AND o.Process = 1
                        AND o.Filled = 1
                        AND o.Void = 0
                    GROUP BY dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0)
                )

                SELECT
                    COALESCE(cdt.TimeStampHour, pwt.TimeStampHour) AS TimeStampHour
                    , ISNULL(cdt.[AccountID], 0) AS ActivatingAccounts
                    , ISNULL(pwt.[AccountID], 0) AS PreviousWeekActivatingAccounts
                    , (ISNULL(cdt.AccountID, 0) - ISNULL(pwt.AccountID, 0)) AS [Difference of Activating Accounts from Last Week]
                    , ISNULL(cdt.[Number Of Order Occurances], 0) AS NumberOfActivations
                    , ISNULL(pwt.[Number Of Order Occurances], 0) AS PreviousWeekNumberOfActivations
                    , (ISNULL(cdt.[Number Of Order Occurances], 0) - ISNULL(pwt.[Number Of Order Occurances], 0))
                        AS [Difference of Activations from Last Week]

                FROM #CurrentDateTXNs AS cdt
                FULL OUTER JOIN #PreviousWeekTXNs AS pwt ON cdt.TimeStampHour = DATEADD(DAY, +14, pwt.TimeStampHour)
                WHERE cdt.[Number Of Order Occurances] IS NOT NULL
                ORDER BY cdt.TimeStampHour
            END;

        IF @OrderType = 1 --Top-Ups
            BEGIN
                (
                    SELECT
                        dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0) AS TimeStampHour,
                        Count(o.Order_No) AS [Number Of Order Occurances],
                        COUNT(DISTINCT a.Account_ID) AS [AccountID]
                    INTO #PreviousWeekTopupTXNs
                    FROM dbo.Order_No AS o
                    JOIN dbo.Account AS a
                        ON a.Account_ID = o.Account_ID
                    JOIN dbo.Orders AS o1
                        ON o1.Order_No = o.Order_No
                    JOIN Products.tblProductCarrierMapping AS pcm
                        ON o1.Product_ID = pcm.ProductId
                    WHERE
                        pcm.CarrierId IN (@Carrier)
                        AND o.DateOrdered >= DATEADD(DAY, -14, @StartDate) AND o.DateOrdered <= DATEADD(DAY, -14, @EndDate)
                        AND o.OrderType_ID IN (1, 9)
                        AND o.Process = 1
                        AND o.Filled = 1
                        AND o.Void = 0
                    GROUP BY dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0)
                )

                (
                    SELECT
                        dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0) AS TimeStampHour,
                        COUNT(o.Order_No) AS [Number Of Order Occurances],
                        COUNT(DISTINCT a.Account_ID) AS [AccountID]
                    INTO #CurrentDateTopupTXNs
                    FROM dbo.Order_No AS o
                    JOIN dbo.Account AS a
                        ON a.Account_ID = o.Account_ID
                    JOIN dbo.Orders AS o1
                        ON o1.Order_No = o.Order_No
                    JOIN Products.tblProductCarrierMapping AS pcm
                        ON o1.Product_ID = pcm.ProductId
                    WHERE
                        pcm.CarrierId IN (@Carrier)
                        AND o.DateOrdered >= @StartDate AND o.DateOrdered <= @EndDate
                        AND o.OrderType_ID IN (1, 9)
                        AND o.Process = 1
                        AND o.Filled = 1
                        AND o.Void = 0
                    GROUP BY dateadd(HOUR, datediff(HOUR, 0, o.DateOrdered), 0)
                )

                SELECT
                    COALESCE(cdt.TimeStampHour, pwt.TimeStampHour) AS TimeStampHour
                    , ISNULL(cdt.[AccountID], 0) AS NumberOfTopUpAccounts
                    , ISNULL(pwt.[AccountID], 0) AS PreviousWeekNumberOfTopUpAccounts
                    , (ISNULL(cdt.AccountID, 0) - ISNULL(pwt.AccountID, 0)) AS [Difference of TopUp Accounts from Last Week]
                    , ISNULL(cdt.[Number Of Order Occurances], 0) AS NumberOfTopUps
                    , ISNULL(pwt.[Number Of Order Occurances], 0) AS PreviousWeekNumberOfTopUps
                    , (ISNULL(cdt.[Number Of Order Occurances], 0) - ISNULL(pwt.[Number Of Order Occurances], 0))
                        AS [Difference of TopUps from Last Week]

                FROM #CurrentDateTopupTXNs AS cdt
                FULL OUTER JOIN #PreviousWeekTopupTXNs AS pwt ON cdt.TimeStampHour = DATEADD(DAY, +14, pwt.TimeStampHour)
                WHERE cdt.[Number Of Order Occurances] IS NOT NULL
                ORDER BY cdt.TimeStampHour
            END;

        DROP TABLE IF EXISTS #PreviousWeekTXNs
        DROP TABLE IF EXISTS #CurrentDateTXNs
        DROP TABLE IF EXISTS #PreviousWeekTopUpTXNs
        DROP TABLE IF EXISTS #CurrentDateTopUpTXNs





    END TRY
    BEGIN CATCH
        SELECT ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;


END;
