--liquibase formatted sql
--changeset MoeDaaboul:795f1910 stripComments:false runOnChange:true splitStatements:false
-- =============================================
-- Author:		zaher al sabbagh
-- Create date: 2015-10-26
-- Description:	get the first and second level for the delay spiff dashboard
-- =============================================
ALTER PROCEDURE [Report].[P_Report_GetInstantSpiffDashboardHeader]
    -- Add the parameters for the stored procedure here
    @Account_ID INT,
    @StartDate DATETIME,
    @EndDate DATETIME
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;

    -- Insert statements for procedure here
    SELECT
        a.[Date_Ordered],
        a.CarrierID,
        a.Carrier_Name,
        SUM([Submitted Activation]) AS [Submitted Activation],
        SUM([Instant Spiff]) AS [Instant Spiff],
        SUM([Charge Back Count]) AS [Charge Back Count],
        SUM([Charge Back Amount]) AS [Charge Back Amount],
        SUM([RetroSpiff Count]) AS [RetroSpiff Count],
        SUM([RetroSpiff Amount]) AS [RetroSpiff Amount]
    FROM (
        SELECT
            CAST(o.DateOrdered AS DATE) AS [Date_Ordered],
            COUNT(o.Order_No) AS [Submitted Activation],
            SUM(o2.Price) AS [Instant Spiff],
            0 AS [Charge Back Count],
            0 AS [Charge Back Amount],
            0 AS [RetroSpiff Count],
            0 AS [RetroSpiff Amount],
            c.id AS [CarrierID],
            c.Carrier_Name
        FROM dbo.Order_No AS o
        JOIN dbo.Orders AS o1 WITH (READUNCOMMITTED)
            ON
                o1.Order_No = o.Order_No
                AND o1.ParentItemID = 0
        JOIN dbo.Orders AS o2 WITH (READUNCOMMITTED)
            ON
                o2.Order_No = o.Order_No
                AND o2.ParentItemID != 0
        JOIN dbo.Product_Category AS pc WITH (READUNCOMMITTED) ON pc.Product_ID = o1.Product_ID
        JOIN dbo.Categories AS cat ON pc.Category_ID = cat.Category_ID
        JOIN dbo.Carrier_ID AS c ON c.Category_ID = cat.Parent_ID
        JOIN dbo.Products AS p ON o2.Product_ID = p.Product_ID
        WHERE
            o.OrderType_ID IN (22, 23)
            AND o.DateOrdered >= @StartDate
            AND o.DateOrdered < @EndDate
            AND o.Filled = 1
            AND o.Process = 1
            AND o.Void = 0
            AND o2.Price != 0
            AND p.Product_Type = 4
            AND o.Account_ID = @Account_ID
        GROUP BY
            CAST(o.DateOrdered AS DATE),
            c.id,
            c.Carrier_Name
        UNION ALL
        SELECT
            CAST(o.DateOrdered AS DATE) AS [Date_Ordered],
            0 AS [Submitted Activation],
            0 AS [Instant Spiff],
            0 AS [Charge Back Count],
            0 AS [Charge Back Amount],
            COUNT(o.Order_No) AS [RetroSpiff Count],
            SUM(o.OrderTotal) AS [RetroSpiff Amount],
            c.id AS [CarrierID],
            c.Carrier_Name
        FROM dbo.Order_No AS o
        JOIN dbo.Order_No AS o1 WITH (READUNCOMMITTED) ON o1.Order_No = o.AuthNumber
        JOIN dbo.Orders AS o3 WITH (READUNCOMMITTED)
            ON
                o3.Order_No = o1.Order_No
                AND o3.ParentItemID != 0
                AND o3.Price != 0
        JOIN dbo.Orders AS o2 WITH (READUNCOMMITTED)
            ON
                o2.Order_No = o1.Order_No
                AND o2.ParentItemID = 0
                AND o2.Price != 0
        JOIN dbo.Product_Category AS pc WITH (READUNCOMMITTED) ON pc.Product_ID = o2.Product_ID
        JOIN dbo.Categories AS cat ON pc.Category_ID = cat.Category_ID
        JOIN dbo.Carrier_ID AS c ON c.Category_ID = cat.Parent_ID
        WHERE
            o.OrderType_ID IN (45, 46)
            AND o.DateOrdered >= @StartDate
            AND o.DateOrdered < @EndDate
            AND o.Filled = 1
            AND o.Process = 1
            AND o.Void = 0
            AND o.Account_ID = @Account_ID
        GROUP BY
            CAST(o.DateOrdered AS DATE),
            c.id,
            c.Carrier_Name
        UNION ALL
        SELECT
            CAST(o.DateOrdered AS DATE) AS [Date_Ordered],
            0 AS [Submitted Activation],
            0 AS [Instant Spiff],
            COUNT(o.Order_No) AS [Charge Back Count],
            SUM(o.OrderTotal) AS [Charge Back Amount],
            0 AS [RetroSpiff Count],
            0 AS [RetroSpiff Amount],
            c.id AS [CarrierID],
            c.Carrier_Name
        FROM dbo.Order_No AS o
        JOIN dbo.Order_No AS o1 WITH (READUNCOMMITTED) ON o1.Order_No = o.AuthNumber
        JOIN dbo.Orders AS o3 WITH (READUNCOMMITTED)
            ON
                o3.Order_No = o1.Order_No
                AND o3.ParentItemID != 0
                AND o3.Price != 0
        JOIN dbo.Orders AS o2 WITH (READUNCOMMITTED)
            ON
                o2.Order_No = o1.Order_No
                AND o2.ParentItemID = 0
                AND o2.Price != 0
        JOIN dbo.Product_Category AS pc WITH (READUNCOMMITTED) ON pc.Product_ID = o2.Product_ID
        JOIN dbo.Categories AS cat ON pc.Category_ID = cat.Category_ID
        JOIN dbo.Carrier_ID AS c ON c.Category_ID = cat.Parent_ID
        WHERE
            o.OrderType_ID IN (31, 32)
            AND o.DateOrdered >= @StartDate
            AND o.DateOrdered < @EndDate
            AND o.Filled = 1
            AND o.Process = 1
            AND o.Void = 0
            AND o.Account_ID = @Account_ID
        GROUP BY
            CAST(o.DateOrdered AS DATE),
            c.id,
            c.Carrier_Name
    ) AS a
    GROUP BY
        a.[Date_Ordered],
        a.[CarrierID],
        a.Carrier_Name



--		SELECT  [Date_Ordered] ,
--CarrierID,a.Carrier_Name,
--        SUM([Submitted Activation]) [Submitted Activation] ,
--		SUM([Instant Spiff]) [Instant Spiff],
--        SUM([Charge Back Count]) [Charge Back Count] ,
--        SUM([Charge Back Amount]) [Charge Back Amount] ,
--        SUM([RetroSpiff Count]) [RetroSpiff Count] ,
--        SUM([RetroSpiff Amount]) [RetroSpiff Amount]
--FROM    (

--SELECT    CAST(o.DateOrdered AS DATE) [Date_Ordered] ,
--                    COUNT(o.Order_No) [Submitted Activation] ,
--                    ABS(SUM(ISNULL(o2.Price, 0))) [Instant Spiff] ,
--					c.ID [CarrierID], c.Carrier_Name,
--					ABS(ISNULL(CASE WHEN o4.Order_No IS NOT NULL THEN COUNT(o4.Order_No) END,0)) [Charge Back Count],
--					ABS(ISNULL(CASE WHEN o4.OrderTotal IS NOT NULL THEN SUM(o4.OrderTotal) END,0)) [Charge Back Amount],
--					ABS(ISNULL(CASE WHEN o3.Order_No IS NOT NULL THEN COUNT(o3.Order_No) END,0)) [RetroSpiff Count],
--					ABS(ISNULL(CASE WHEN o3.OrderTotal IS NOT NULL THEN SUM(o3.OrderTotal) END,0)) [RetroSpiff Amount]

--          FROM      dbo.Order_No o WITH ( READUNCOMMITTED )
--                    JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON o1.Order_No = o.Order_No
--                                                              AND ParentItemID = 0
--                    JOIN dbo.Orders o2 WITH ( READUNCOMMITTED ) ON o2.Order_No = o.Order_No
--                                                              AND o2.ParentItemID != 0
--                    LEFT JOIN dbo.Order_No o3 WITH ( READUNCOMMITTED ) ON CAST(o.Order_No AS NVARCHAR(50)) = o3.AuthNumber
--                                                              AND o3.OrderType_ID IN (
--                                                              45, 46 )
--                                                              AND o3.Filled = 1 AND o3.Process = 1 AND o3.Void = 0
--					LEFT JOIN dbo.Order_No o4 WITH ( READUNCOMMITTED ) ON CAST(o.Order_No AS NVARCHAR(50)) = o4.AuthNumber
--                                                              AND o4.OrderType_ID IN (
--                                                              31,32 )
--                                                              AND o4.Filled = 1 AND o4.Process = 1 AND o4.Void = 0
--					JOIN dbo.Product_Category pc WITH(READUNCOMMITTED) ON pc.Product_ID = o1.Product_ID
--					JOIN dbo.Categories cat ON pc.Category_ID = cat.Category_ID
--					JOIN dbo.Carrier_ID c ON c.Category_ID = cat.Parent_ID
--          WHERE     o.OrderType_ID IN ( 22, 23 )
--                    AND o.DateOrdered < @EndDate
--                    AND o.DateOrdered >= @StartDate
--                    AND o.Filled = 1
--                    AND o.Process = 1
--                    AND o.Void = 0
--                    AND o2.Price != 0
--					AND o.Account_ID = @Account_ID
--					GROUP BY
--					CAST(o.DateOrdered AS DATE) ,
--					c.ID, c.Carrier_Name,o3.Order_No, o4.Order_No, o3.OrderTotal, o4.OrderTotal) AS a
--					GROUP BY [Date_Ordered], [CarrierID],a.Carrier_Name



END
